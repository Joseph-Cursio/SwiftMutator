import ArgumentParser
import Foundation

/// The verdict of a run, or of `report`, on its score against a baseline file's (`--baseline`, `--max-score-drop`):
/// it fails when the score fell more points below the file's than the limit allows, and then exits 2
/// (`ExitCode.scoreBelowThreshold`, the status of every failed check, as #96 gives them), once every report is
/// written. The run's score is the one `ScoreGate` checks, with any mutant taken out of the build with others counted
/// as not killed; the file's is the one it records, of the same counts (`BaselineFile.Score`). Both are compared
/// exactly, from the counts, never as the reports show them, so a drop equal to the limit passes.
///
/// Only a whole project's score compares with the file's, which a whole run wrote: a run of one mutant, a shard's,
/// a sample's, one of `--since` or `--files-to-mutate`, one that didn't finish, and shards whose runs discovered
/// different mutants aren't checked, and say why.
struct ScoreDropCheck: Equatable, Sendable {
    /// The baseline file, as given.
    let baseline: String
    /// How many points the score may fall below the file's, from 0 to 100.
    let maxScoreDrop: Double
    /// The file's counts, killed of scored.
    let baselineScore: BaselineFile.Score
    /// The run's counts, killed of scored, as `ScoreGate` takes them.
    let killed: Int
    let scored: Int
    let verdict: Verdict
    /// For `report` of a run that didn't finish, how many of its mutants have results, which the line says; nil
    /// otherwise.
    let progress: ScoreGate.Progress?

    enum Verdict: Equatable, Sendable {
        /// The score fell no more than the limit below the file's, or rose.
        case passed
        /// The score fell more than the limit below the file's.
        case failed
        /// The score isn't the whole project's, or isn't known to be, or either side scored nothing, so the two
        /// aren't compared.
        case notChecked(NotChecked)
    }

    /// Why the scores aren't compared.
    enum NotChecked: String, Codable, Sendable {
        /// The run tested one mutant alone (`--mutant`).
        case oneMutant
        /// The outcome is one shard's, or some shards', of a `--shard` split.
        case shard
        /// The run tested a sample (`--sample`).
        case sample
        /// The run tested only the code `--since` chose.
        case since
        /// The run tested only the files `--files-to-mutate` chose.
        case filesToMutate
        /// The run didn't test every mutant it discovered: `report` of a run that didn't finish.
        case unfinished
        /// The run, or the baseline file, scored no mutant, so has no score.
        case nothingScored
        /// The run stopped before it finished, by a signal or an error, and says so itself.
        case endedEarly
        /// `report` of a run that stopped on an error, which exits as the run did.
        case stoppedOnAnError
        /// `report` of shards whose merged report lacks results (`MergedShards.lacksResults`).
        case lacksResults
        /// `report` of every shard of a split, merged, whose runs didn't discover the same mutants
        /// (`MergedShards.discoveriesAgree`), so some may have no result.
        case discoveriesDiffer
    }

    /// The verdict on `outcome`'s score against `baseline`'s, allowing it to fall `maxScoreDrop` points: not checked,
    /// for the reason `unless` gives, for results that aren't the whole project's (`notChecked(of:progress:)`), or
    /// when either side scored nothing. `progress` is that of a run that didn't finish, which isn't checked.
    init(
        baseline: BaselineFile,
        maxScoreDrop: Double,
        judging outcome: MutationTestOutcome,
        unless notChecked: NotChecked? = nil,
        progress: ScoreGate.Progress? = nil
    ) {
        let gate = ScoreGate(failUnder: 0, judging: outcome)
        self.init(
            baseline: baseline,
            maxScoreDrop: maxScoreDrop,
            killed: gate.killed,
            scored: gate.scored,
            unless: notChecked ?? Self.notChecked(of: outcome, progress: progress)
                // Those left out with others count as not killed, but alone they're no score, as `ScoreGate` has it.
                ?? (gate.scored == gate.leftOutWithOthers ? .nothingScored : nil),
            progress: progress
        )
    }

    /// The verdict on a score of `killed` of `scored` mutants against `baseline`'s, allowing it to fall `maxScoreDrop`
    /// points: not checked, for the reason `unless` gives, or when either side scored nothing.
    init(
        baseline: BaselineFile,
        maxScoreDrop: Double,
        killed: Int,
        scored: Int,
        unless notChecked: NotChecked? = nil,
        progress: ScoreGate.Progress? = nil
    ) {
        let reason = notChecked ?? (scored == 0 || baseline.score.scored == 0 ? .nothingScored : nil)
        let verdict: Verdict
        if let reason {
            verdict = .notChecked(reason)
        } else {
            let drop = Self.drop(from: baseline.score, to: (killed, scored))
            verdict = drop.points > Self.decimal(maxScoreDrop) * drop.over ? .failed : .passed
        }
        self.init(
            baseline: baseline.path,
            maxScoreDrop: maxScoreDrop,
            baselineScore: baseline.score,
            killed: killed,
            scored: scored,
            verdict: verdict,
            progress: reason == .unfinished ? progress : nil
        )
    }

    init(
        baseline: String,
        maxScoreDrop: Double,
        baselineScore: BaselineFile.Score,
        killed: Int,
        scored: Int,
        verdict: Verdict,
        progress: ScoreGate.Progress? = nil
    ) {
        self.baseline = baseline
        self.maxScoreDrop = maxScoreDrop
        self.baselineScore = baselineScore
        self.killed = killed
        self.scored = scored
        self.verdict = verdict
        self.progress = progress
    }

    /// Why `outcome`'s score isn't the whole project's, which a baseline file's is: one mutant's, a shard's, a
    /// sample's, the code `--since` or `--files-to-mutate` chose, or some of the mutants a run discovered, as `report`
    /// of one that didn't finish has, which `progress` says; nil for a whole run's.
    static func notChecked(of outcome: MutationTestOutcome, progress: ScoreGate.Progress?) -> NotChecked? {
        if outcome.mutant != nil { return .oneMutant }
        if outcome.shards != nil { return .shard }
        if outcome.sample != nil { return .sample }
        if outcome.since != nil { return .since }
        if !outcome.filesToMutate.isEmpty { return .filesToMutate }
        if progress != nil || outcome.sampleIsCutShort { return .unfinished }
        return nil
    }

    /// Whether the score fell no more than the limit; nil when the two aren't compared.
    var passed: Bool? {
        switch verdict {
        case .passed: true
        case .failed: false
        case .notChecked: nil
        }
    }

    /// The status a command exits with for this verdict: `scoreBelowThreshold` for a drop past the limit, and nil, so
    /// 0, otherwise.
    var exitStatus: ExitCode? {
        passed == false ? .scoreBelowThreshold : nil
    }

    /// The run's exact score, as compared; nil when the scores aren't compared.
    var score: Double? {
        passed == nil ? nil : exactMutationScore(killed: killed, of: scored)
    }

    /// The baseline file's exact score, as compared; nil when the scores aren't compared.
    var baselineScorePercent: Double? {
        passed == nil ? nil : exactMutationScore(killed: baselineScore.killed, of: baselineScore.scored)
    }

    /// How many points the score fell below the file's, negative for a rise; nil when they aren't compared. Worked out
    /// from the counts, as the verdict is, never as the difference of the two scores above, which may each be a little
    /// off: so a drop equal to the limit is the very number `--max-score-drop` was given, and `drop <= maxScoreDrop`
    /// holds exactly when the check passed.
    var drop: Double? {
        guard passed != nil else { return nil }
        let drop = Self.drop(from: baselineScore, to: (killed, scored))
        // Through the decimal text, which `Double` reads with correct rounding, as it read the limit.
        return Double(NSDecimalNumber(decimal: drop.points / drop.over).stringValue)
    }

    /// What the run, or `report`, says of the verdict, after the score's: "Mutation score 81.2% is 1.4 points below
    /// the baseline file muter.baseline.yml's 82.6%, within the 2 allowed." No emoji, which a run adds
    /// (`consoleLines`). nil for a run that ended early, which says why itself.
    ///
    /// Both scores show as many decimals as the limit has, at least 1, truncated as `ScoreGate` shows its score, so
    /// each shows its whole percent as the reports do, and the drop, or the rise, as the difference of the two shown,
    /// so the line adds up. A drop within the limit then never shows past it: the shown scores are each less than a
    /// last decimal below the exact ones, so their difference is less than a last decimal past the drop, and the limit
    /// is a whole number of last decimals. A drop past the limit can show within it, as 82.09% against 80% with 2
    /// allowed shows 82.0% and 80.0%: it shows with one more decimal at a time until it shows past it, as 2.09.
    var line: String? {
        let file = "the baseline file \(baseline)"
        guard case .notChecked = verdict else { return comparedSentence(file: file) }
        return notCheckedSentence(file: file)
    }

    /// What a run prints of the verdict: `line`, with ✅ when it passes, ❌ when the score fell too far, and ⚠️ when
    /// the scores aren't compared. Empty when there's no line.
    var consoleLines: [String] {
        guard let line else { return [] }
        let emoji = switch passed {
        case .some(true): "✅"
        case .some(false): "❌"
        case .none: "⚠️"
        }
        return ["\(emoji) \(line)"]
    }

    /// The two scores compared, and how far the run's is below or above `file`'s, or that they are the same.
    private func comparedSentence(file: String) -> String {
        let limit = Self.decimal(maxScoreDrop)
        var decimals = max(1, Self.decimals(of: maxScoreDrop))
        var shown = shownScores(decimals: decimals)
        while passed == false, shown.recorded - shown.run <= limit, decimals < Self.mostDecimalsShown {
            decimals += 1
            shown = shownScores(decimals: decimals)
        }
        let drop = Self.drop(from: baselineScore, to: (killed, scored))
        let opening = "Mutation score \(Self.written(shown.run, decimals: decimals))%"
        guard drop.points != 0 else { return "\(opening) is the same as \(file)'s." }
        let recorded = "\(file)'s \(Self.written(shown.recorded, decimals: decimals))%"
        let gap = shown.recorded - shown.run
        // Scores that show the same differ by less than a last decimal.
        let points = gap == 0
            ? "less than 0." + String(repeating: "0", count: decimals - 1) + "1 points"
            : "\(Self.written(gap < 0 ? -gap : gap, decimals: decimals)) points"
        guard drop.points > 0 else { return "\(opening) is \(points) above \(recorded)." }
        let allowed = "the \(ScoreGate.shown(maxScoreDrop)) allowed"
        return "\(opening) is \(points) below \(recorded), \(passed == true ? "within" : "more than") \(allowed)."
    }

    /// The run's score and the file's, each truncated to `decimals` decimals.
    private func shownScores(decimals: Int) -> (run: Decimal, recorded: Decimal) {
        (
            Self.truncated(Decimal(killed) * 100, over: Decimal(scored), decimals: decimals),
            Self.truncated(
                Decimal(baselineScore.killed) * 100,
                over: Decimal(baselineScore.scored),
                decimals: decimals
            )
        )
    }

    /// How many decimals a line shows at most, however little a drop is past the limit. A drop is a fraction over the
    /// two scored counts multiplied, so with fewer than a few million mutants scored on each side, one past the limit
    /// shows past it well before this.
    private static let mostDecimalsShown = 20

    /// Why the scores aren't compared; nil for a run that ended early.
    private func notCheckedSentence(file: String) -> String? {
        guard case let .notChecked(reason) = verdict else { return nil }
        let notChecked = "The score isn't compared with \(file)'s"
        switch reason {
        case .oneMutant:
            return "\(notChecked): one mutant's score (--mutant) isn't the project's."
        case .shard:
            return "\(notChecked): a shard's score isn't the whole run's. Compare the merged report instead: "
                + "swift-mutator report --baseline \(baseline) --max-score-drop \(ScoreGate.shown(maxScoreDrop)) "
                + "<each shard's results file>"
        case .sample:
            return "\(notChecked): a sample's score (--sample) isn't the whole project's."
        case .since:
            return "\(notChecked): the score of the code --since chose isn't the whole project's."
        case .filesToMutate:
            return "\(notChecked): the score of the files --files-to-mutate chose isn't the whole project's."
        case .unfinished:
            guard let progress else {
                return "\(notChecked): the run didn't test every mutant it discovered."
            }
            return "\(notChecked): only \(progress.results) of \(progress.discovered) mutants have results, as the "
                + "run didn't finish."
        case .nothingScored:
            return baselineScore.scored == 0
                ? "\(notChecked): the baseline file records no mutant scored."
                : "\(notChecked): no mutant was scored."
        case .stoppedOnAnError:
            return "\(notChecked): the run stopped on an error."
        case .lacksResults:
            return "\(notChecked): the merged report lacks results."
        case .discoveriesDiffer:
            return "\(notChecked): the shards' runs didn't discover the same mutants, so some may have no result."
        case .endedEarly:
            return nil
        }
    }

    /// How many points `run`'s score, killed of scored, fell below `recorded`'s, as a fraction of whole numbers,
    /// `points` over `over`, so it compares exactly: negative for a rise. Both must have scored some.
    /// 100 × (k₀/s₀ − k/s) = 100 × (k₀·s − k·s₀) / (s₀·s).
    private static func drop(
        from recorded: BaselineFile.Score,
        to run: (killed: Int, scored: Int)
    ) -> (points: Decimal, over: Decimal) {
        let recordedKilled = Decimal(recorded.killed) * Decimal(run.scored)
        let runKilled = Decimal(run.killed) * Decimal(recorded.scored)
        return ((recordedKilled - runKilled) * 100, Decimal(recorded.scored) * Decimal(run.scored))
    }

    /// `value` as a `Decimal`, exactly as it is written (`ScoreGate.shown`), so 0.1 is a tenth, not the `Double`
    /// nearest it.
    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: ScoreGate.shown(value), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    }

    /// How many decimals `value` is written with, at most `ScoreGate.maximumDecimals`: 0 for 2, 1 for 1.5.
    private static func decimals(of value: Double) -> Int {
        let written = ScoreGate.shown(value)
        guard let point = written.firstIndex(of: ".") else { return 0 }
        return min(ScoreGate.maximumDecimals, written.distance(from: point, to: written.endIndex) - 1)
    }

    /// `numerator` over `denominator`, both 0 or more, truncated to `decimals` decimals.
    private static func truncated(_ numerator: Decimal, over denominator: Decimal, decimals: Int) -> Decimal {
        var quotient = numerator / denominator
        var truncated = Decimal()
        NSDecimalRound(&truncated, &quotient, decimals, .down)
        return truncated
    }

    /// `value`, 0 or more with at most `decimals` decimals, written with exactly that many: "81.2".
    private static func written(_ value: Decimal, decimals: Int) -> String {
        let written = NSDecimalNumber(decimal: value).stringValue
        let parts = written.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        return "\(parts[0])." + fraction + String(repeating: "0", count: max(0, decimals - fraction.count))
    }

    /// `--max-score-drop`'s value: a plain decimal number of points from 0 to 100, with at most
    /// `ScoreGate.maximumDecimals` decimals, as `--fail-under` takes its percent (`ScoreGate.percent`); nil for
    /// anything else.
    static func points(_ text: String) -> Double? {
        ScoreGate.percent(text)
    }
}
