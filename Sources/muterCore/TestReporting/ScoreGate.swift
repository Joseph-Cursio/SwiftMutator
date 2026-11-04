import ArgumentParser
import Foundation

/// The verdict of a run, or of `report`, on its headline score against the threshold `--fail-under` or `failUnder`
/// sets. It compares the exact score (`exactMutationScore(killed:of:)`), never the whole percent the reports show, so
/// a change in how the score is shown can't change it, and a score equal to the threshold passes. A score below it
/// exits 2 (`ExitCode.scoreBelowThreshold`), once every report is written.
struct ScoreGate: Equatable, Sendable {
    /// The thresholds `--fail-under` and `failUnder` take.
    static let percents: ClosedRange<Double> = 0 ... 100
    /// The most decimals a threshold is written with, which the score is shown with too (`shownScore`), so the two
    /// can always be told apart.
    static let maximumDecimals = 6

    /// The threshold, a percent from 0 to 100.
    let failUnder: Double
    /// The mutants killed, and those scored, of which the score is.
    let killed: Int
    let scored: Int
    let verdict: Verdict
    /// How many of the mutants discovered have results, for `report` of a run that didn't finish; nil otherwise.
    let progress: Progress?

    struct Progress: Equatable, Sendable {
        let results: Int
        let discovered: Int
    }

    enum Verdict: Equatable, Sendable {
        /// The score is at or above the threshold.
        case passed
        /// The score is below the threshold.
        case failed
        /// No mutant was scored, so no score falls short: none was `tested`, or every one was a build error.
        case nothingScored(tested: Int)
        /// The score isn't the project's, or isn't known to be, so the threshold isn't checked.
        case notChecked(NotChecked)
    }

    /// Why the threshold isn't checked.
    enum NotChecked: String, Codable, Sendable {
        /// The run tested one mutant alone (`--mutant`), whose score isn't the project's.
        case oneMutant
        /// The outcome is one shard's, or some shards', of a `--shard` split, whose score isn't the whole run's.
        case shard
        /// The run stopped before it finished, by a signal or an error, and says so itself.
        case endedEarly
        /// `report` of a run that stopped on an error, which exits as the run did.
        case stoppedOnAnError
        /// `report` of shards whose merged report lacks results (`MergedShards.lacksResults`).
        case lacksResults
    }

    /// The verdict on `outcome` against `failUnder`: not checked, for the reason `unless` gives, for a run of one
    /// mutant, or for some shards of a split; else passed when nothing was scored, as nothing measured falls short, so
    /// a change that touches no Swift code doesn't fail; else as its score compares. `progress`, of a run that didn't
    /// finish, is said with the verdict.
    init(
        failUnder: Double,
        judging outcome: MutationTestOutcome,
        unless notChecked: NotChecked? = nil,
        progress: Progress? = nil
    ) {
        let outcomes = outcome.mutations.map(\.testSuiteOutcome)
        let mutants = scoredMutants(in: outcomes)
        self.failUnder = failUnder
        killed = mutants.killed
        scored = mutants.scored
        self.progress = progress
        if let notChecked {
            verdict = .notChecked(notChecked)
        } else if outcome.mutant != nil {
            verdict = .notChecked(.oneMutant)
        } else if outcome.shards != nil {
            verdict = .notChecked(.shard)
        } else if let score = exactMutationScore(killed: mutants.killed, of: mutants.scored) {
            verdict = score < failUnder ? .failed : .passed
        } else {
            verdict = .nothingScored(tested: outcomes.count)
        }
    }

    /// The exact headline score; nil when no mutant was scored.
    var score: Double? {
        exactMutationScore(killed: killed, of: scored)
    }

    /// Whether the score is checked and isn't below the threshold, which nothing scored isn't; nil when it isn't
    /// checked.
    var passed: Bool? {
        switch verdict {
        case .passed, .nothingScored: true
        case .failed: false
        case .notChecked: nil
        }
    }

    /// The status a command exits with for this verdict: `scoreBelowThreshold` for a score below the threshold, and
    /// nil, so 0, otherwise.
    var exitStatus: ExitCode? {
        verdict == .failed ? .scoreBelowThreshold : nil
    }

    /// What the run, or `report`, says of the verdict, last: "Mutation score 71.4% is below the required 80%." No
    /// emoji, which a run adds (`Logger.scoreGateChecked(_:)`). nil for a run that ended early, which says why itself.
    var line: String? {
        let threshold = "\(Self.shown(failUnder))%"
        let sentence: String
        switch verdict {
        case .passed:
            sentence = "Mutation score \(shownScore)% meets the required \(threshold)."
        case .failed:
            sentence = "Mutation score \(shownScore)% is below the required \(threshold)."
        case .nothingScored(tested: 0):
            sentence = "No mutant was tested, so no score falls short of the required \(threshold)."
        case .nothingScored:
            sentence = "Every mutant tested was a build error, so no score falls short of the required \(threshold)."
        case let .notChecked(reason):
            return Self.notCheckedSentence(reason, failUnder: failUnder)
        }
        guard let progress else { return sentence }
        return sentence + " Only \(progress.results) of \(progress.discovered) mutants have results, as the run "
            + "didn't finish."
    }

    /// Why `failUnder` isn't checked; nil for a run that ended early.
    private static func notCheckedSentence(_ reason: NotChecked, failUnder: Double) -> String? {
        let notChecked = "The required \(shown(failUnder))% isn't checked"
        switch reason {
        case .oneMutant:
            return "\(notChecked): one mutant's score (--mutant) isn't the project's."
        case .shard:
            return "\(notChecked): a shard's score isn't the whole run's. Check the merged report instead: "
                + "swift-mutator report --fail-under \(shown(failUnder)) <each shard's results file>"
        case .stoppedOnAnError:
            return "\(notChecked): the run stopped on an error."
        case .lacksResults:
            return "\(notChecked): the merged report lacks results."
        case .endedEarly:
            return nil
        }
    }

    /// The score, truncated to as many decimals as the threshold has, at least 1, so that a failing score shows
    /// below the threshold, a passing one at or above it, and its whole part is the headline's: 71.4 for 5 of 7
    /// against 80, 79.9 for 799 of 1000 against 80, 79.96 for 1999 of 2500 against 79.95. Worked out from the counts,
    /// so no rounding of a `Double` gets in the way.
    private var shownScore: String {
        let decimals = max(1, Self.decimals(of: failUnder))
        var scale = 1
        for _ in 0 ..< decimals {
            scale *= 10
        }
        let scaled = scored > 0 ? killed * 100 * scale / scored : 0
        let fraction = String(scaled % scale)
        return "\(scaled / scale)." + String(repeating: "0", count: decimals - fraction.count) + fraction
    }

    /// How many decimals `percent` is written with, at most `maximumDecimals`: 0 for 80, 1 for 72.5.
    private static func decimals(of percent: Double) -> Int {
        let written = shown(percent)
        guard let point = written.firstIndex(of: ".") else { return 0 }
        return min(maximumDecimals, written.distance(from: point, to: written.endIndex) - 1)
    }

    /// `percent` as it is written: as a whole number when it is one ("80"), else in fixed notation, as Swift writes
    /// it when it can ("72.5") and to 15 decimals, less the trailing zeros, when Swift would use an exponent
    /// ("0.00001", "0.0000001"). So every threshold `percent(_:)` takes is shown as it was written. A number too large
    /// for a percent, or not finite, which only a refusal shows, as Swift writes it.
    static func shown(_ percent: Double) -> String {
        guard percent.isFinite, abs(percent) < 1e15 else { return "\(percent)" }
        if percent == percent.rounded() {
            return String(Int(percent))
        }
        let written = "\(percent)"
        guard written.contains("e") else { return written }
        var fixed = String(format: "%.15f", percent)
        while fixed.hasSuffix("0") {
            fixed.removeLast()
        }
        if fixed.hasSuffix(".") {
            fixed.removeLast()
        }
        return fixed
    }

    /// The threshold `text` gives, `--fail-under`'s value and `failUnder`'s: a plain decimal number from 0 to 100,
    /// with at most `maximumDecimals` decimals, such as 80 or 72.5; nil for anything else, such as -1, 100.5, 1e2,
    /// 0x50 or 0.0000001.
    static func percent(_ text: String) -> Double? {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let isPlain = parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { ("0" ... "9").contains($0) } }
        let decimals = parts.count > 1 ? parts[1].count : 0
        guard isPlain, decimals <= maximumDecimals, let percent = Double(text), percents.contains(percent) else {
            return nil
        }
        return percent
    }
}
