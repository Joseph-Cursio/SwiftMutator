import ArgumentParser
import Foundation

/// The verdicts a finished run, or `report`, ends with, each of the check its flag asks for, nil without it: the score
/// against `--fail-under` (`ScoreGate`), the survivors against a baseline file (`NewSurvivorsCheck`), the score
/// against the baseline file's (`ScoreDropCheck`), and the kills its evidence doesn't back (`DoubtfulKillsCheck`), in
/// the order they're said.
struct RunChecks: Equatable, Sendable {
    var scoreGate: ScoreGate?
    var newSurvivors: NewSurvivorsCheck?
    var scoreDrop: ScoreDropCheck?
    var doubtfulKills: DoubtfulKillsCheck?

    init(
        scoreGate: ScoreGate? = nil,
        newSurvivors: NewSurvivorsCheck? = nil,
        scoreDrop: ScoreDropCheck? = nil,
        doubtfulKills: DoubtfulKillsCheck? = nil
    ) {
        self.scoreGate = scoreGate
        self.newSurvivors = newSurvivors
        self.scoreDrop = scoreDrop
        self.doubtfulKills = doubtfulKills
    }

    /// Whether no check was asked for.
    var isEmpty: Bool {
        scoreGate == nil && newSurvivors == nil && scoreDrop == nil && doubtfulKills == nil
    }

    /// The status a command exits with when a check failed, `scoreBelowThreshold`; nil, so 0, otherwise.
    var exitStatus: ExitCode? {
        scoreGate?.exitStatus ?? newSurvivors?.exitStatus ?? scoreDrop?.exitStatus ?? doubtfulKills?.exitStatus
    }
}

/// The verdict of a run, or of `report`, on its survivors against a baseline file's (`--baseline`, `BaselineMatches`):
/// it fails when more of its survivors are new than `--max-new-survivors` allows, 0 unless it says otherwise, and then
/// exits 2 (`ExitCode.scoreBelowThreshold`, the status of every failed check, as #96 gives them), once every report is
/// written. Only the mutants the run tested are compared, so a shard, `--since`, `--sample` or `--files-to-mutate` is
/// checked on its own mutants, and an entry for code it didn't test is said as not tested, never as fixed.
struct NewSurvivorsCheck: Equatable, Sendable {
    /// How many new survivors the lines name, one each; summary.json's `newSurvivors.newMutants` lists them all.
    static let shownNewSurvivors = 20

    /// The baseline file, as given.
    let baseline: String
    let maxNewSurvivors: Int
    let verdict: Verdict
    /// A line saying the baseline file was written by another SwiftMutator version, whose operators may differ, so
    /// that new operators' mutants show as new; nil when it's the same one, or the check isn't made.
    let versionNotice: String?
    /// For `report` of a run that didn't finish, how many of its mutants have results, which the line says; nil
    /// otherwise.
    let progress: ScoreGate.Progress?
    /// Whether the survivors' results don't record the mutants of code no test ran
    /// (`MutationTestOutcome.uncoveredMutants`), as an older SwiftMutator's, or a run of a test plan one made, don't:
    /// the line says that new code no test ran isn't seen, and the baseline file's entries for such code are not
    /// tested.
    let uncoveredMutantsUnknown: Bool

    enum Verdict: Equatable, Sendable {
        case checked(Comparison)
        /// The survivors aren't the project's, or aren't known to be, so they aren't compared.
        case notChecked(NotChecked)
    }

    /// What the comparison found.
    struct Comparison: Equatable, Sendable {
        /// The run's survivors the baseline file doesn't record, by their key's description and what they change, in
        /// the run's order.
        let newSurvivors: [NewSurvivor]
        let stillSurvive: Int
        let fixed: Int
        let notTested: Int
        let matchedWithoutLine: Int
    }

    struct NewSurvivor: Equatable, Sendable {
        let mutant: String
        let before: String
        let after: String
        /// Whether coverage left it out: one the run judged not covered, or one of code coverage left out, which it
        /// didn't make (`UncoveredMutant`), as no test ran it, or its file is at or below `coverageThreshold`.
        let notCovered: Bool

        init(mutant: String, before: String, after: String, notCovered: Bool = false) {
            self.mutant = mutant
            self.before = before
            self.after = after
            self.notCovered = notCovered
        }

        /// "Sources/X.swift:42:17 RelationalBoundary: < → <=", and " (coverage left it out)" when `notCovered`.
        var described: String {
            "\(mutant): \(before) → \(after)" + (notCovered ? Self.notCoveredNote : "")
        }

        /// What a new survivor coverage left out is marked with. Not "no test ran it": a file at or below a
        /// `coverageThreshold` above 0 is left out whole, with lines a test ran.
        static let notCoveredNote = " (coverage left it out)"
    }

    /// Why the survivors aren't compared, as `ScoreGate.NotChecked` gives it.
    enum NotChecked: String, Codable, Sendable {
        /// The run tested one mutant alone (`--mutant`).
        case oneMutant
        /// The run stopped before it finished, by a signal or an error, and says so itself.
        case endedEarly
        /// `report` of a run that stopped on an error, which exits as the run did.
        case stoppedOnAnError
        /// `report` of shards whose merged report lacks results (`MergedShards.lacksResults`).
        case lacksResults
    }

    /// The verdict on `outcome`'s survivors against `baseline`'s, allowing `maxNewSurvivors` new ones: not checked, for
    /// the reason `unless` gives, or for a run of one mutant. `version` is the SwiftMutator that tested `outcome`,
    /// which a line notes when the baseline file's was another. `progress`, of a run that didn't finish, is said in
    /// the line, as `ScoreGate` says it. Each mutant's line is read by `readSource`.
    ///
    /// When `outcome` left out mutants it doesn't know (`MutationTestOutcome.leavesOutUnknownMutants`), or didn't
    /// finish, an entry is paired only at its own key: one for a mutant not tested could take an identical one that
    /// was, which would hide a new survivor.
    init(
        baseline: BaselineFile,
        maxNewSurvivors: Int,
        judging outcome: MutationTestOutcome,
        version: String,
        unless notChecked: NotChecked? = nil,
        progress: ScoreGate.Progress? = nil,
        readingSourcesWith readSource: @escaping ReadFile = dependency(\.readSourceFile)
    ) {
        self.baseline = baseline.path
        self.maxNewSurvivors = maxNewSurvivors
        let reason = notChecked ?? (outcome.mutant != nil ? .oneMutant : nil)
        if let reason {
            verdict = .notChecked(reason)
            versionNotice = nil
            self.progress = nil
            uncoveredMutantsUnknown = false
            return
        }
        self.progress = progress
        uncoveredMutantsUnknown = outcome.uncoveredMutants == nil
        let matches = BaselineMatches(
            baseline.survivors,
            against: BaselineMatches.TestedMutant.all(of: outcome, readingSourcesWith: readSource),
            exactKeysOnly: outcome.leavesOutUnknownMutants || progress != nil
        )
        verdict = .checked(Comparison(
            newSurvivors: matches.newSurvivors.map {
                NewSurvivor(mutant: $0.key.description, before: $0.before, after: $0.after, notCovered: $0.isNotCovered)
            },
            stillSurvive: matches.stillSurvive,
            fixed: matches.fixed.count,
            notTested: matches.notTested.count,
            matchedWithoutLine: matches.matchedWithoutLine
        ))
        versionNotice = baseline.swiftMutator == version ? nil
            : "The baseline file \(baseline.path) was written by SwiftMutator \(baseline.swiftMutator), and these "
            + "survivors by \(version): a new or changed operator's mutants may show as new survivors."
    }

    init(
        baseline: String,
        maxNewSurvivors: Int,
        verdict: Verdict,
        versionNotice: String? = nil,
        progress: ScoreGate.Progress? = nil,
        uncoveredMutantsUnknown: Bool = false
    ) {
        self.baseline = baseline
        self.maxNewSurvivors = maxNewSurvivors
        self.verdict = verdict
        self.versionNotice = versionNotice
        self.progress = progress
        self.uncoveredMutantsUnknown = uncoveredMutantsUnknown
    }

    /// Whether the run has no more new survivors than allowed; nil when they aren't compared.
    var passed: Bool? {
        guard case let .checked(comparison) = verdict else { return nil }
        return comparison.newSurvivors.count <= maxNewSurvivors
    }

    /// The status a command exits with for this verdict: `scoreBelowThreshold` for too many new survivors, and nil, so
    /// 0, otherwise.
    var exitStatus: ExitCode? {
        passed == false ? .scoreBelowThreshold : nil
    }

    /// What the run, or `report`, says of the verdict, after the score's: "2 new survivors against the baseline file
    /// muter.baseline.yml, more than the 0 allowed: 41 still survive, 3 fixed." No emoji, which a run adds
    /// (`Logger.newSurvivorsChecked(_:)`). nil for a run that ended early, which says why itself.
    var line: String? {
        let file = "the baseline file \(baseline)"
        switch verdict {
        case let .notChecked(reason):
            return Self.notCheckedSentence(reason, file: file)

        case let .checked(comparison):
            let new = comparison.newSurvivors.count
            let survivors = new == 1 ? "1 new survivor" : "\(new) new survivors"
            let allowed = "the \(maxNewSurvivors) allowed"
            let opening = if new == 0 {
                "No new survivors against \(file)"
            } else if new > maxNewSurvivors {
                "\(survivors) against \(file), more than \(allowed)"
            } else {
                "\(survivors) against \(file), within \(allowed)"
            }
            var counts = "\(comparison.stillSurvive) still survive, \(comparison.fixed) fixed"
            if comparison.notTested > 0 {
                counts += ", \(comparison.notTested) not tested"
            }
            var sentence = "\(opening): \(counts)."
            if comparison.matchedWithoutLine > 0 {
                sentence += comparison.matchedWithoutLine == 1
                    ? " 1 was matched without its line, as its file changed since it was tested, or can't be read."
                    : " \(comparison.matchedWithoutLine) were matched without their line, as their files changed "
                    + "since they were tested, or can't be read."
            }
            if let progress {
                sentence += " Only \(progress.results) of \(progress.discovered) mutants have results, as the run "
                    + "didn't finish."
            }
            if uncoveredMutantsUnknown {
                sentence += " The results don't record the mutants of code no test ran, so new code no test ran isn't "
                    + "seen."
            }
            return sentence
        }
    }

    /// `line`, then one indented line for each new survivor, up to `shownNewSurvivors`, then how many more; empty
    /// when there's no line.
    var lines: [String] {
        guard let line else { return [] }
        guard case let .checked(comparison) = verdict else { return [line] }
        let hidden = comparison.newSurvivors.count - Self.shownNewSurvivors
        return [line]
            + comparison.newSurvivors.prefix(Self.shownNewSurvivors).map { "  " + $0.described }
            + (hidden > 0 ? ["  …and \(hidden) more"] : [])
    }

    /// What a run prints of the verdict: a line noting the baseline file's other SwiftMutator version, then `lines`,
    /// the first with ✅ when it passes, ❌ when too many survivors are new, and ⚠️ when they aren't compared. Empty
    /// when there's no line.
    var consoleLines: [String] {
        let verdictLines = lines
        guard let firstLine = verdictLines.first else { return [] }
        let emoji = switch passed {
        case .some(true): "✅"
        case .some(false): "❌"
        case .none: "⚠️"
        }
        return (versionNotice.map { ["⚠️ \($0)"] } ?? []) + ["\(emoji) \(firstLine)"] + verdictLines.dropFirst()
    }

    /// Why the survivors aren't compared; nil for a run that ended early.
    private static func notCheckedSentence(_ reason: NotChecked, file: String) -> String? {
        let notChecked = "The survivors aren't compared with \(file)"
        switch reason {
        case .oneMutant:
            return "\(notChecked): one mutant's run (--mutant) isn't the project's."

        case .stoppedOnAnError:
            return "\(notChecked): the run stopped on an error."

        case .lacksResults:
            return "\(notChecked): the merged report lacks results."

        case .endedEarly:
            return nil
        }
    }

    /// `--max-new-survivors`' value, a whole number, 0 or more; nil for anything else.
    static func allowed(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ ("0" ... "9").contains($0) }) else { return nil }
        return Int(text)
    }
}
