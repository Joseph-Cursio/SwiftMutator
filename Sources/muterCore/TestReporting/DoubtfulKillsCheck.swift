import ArgumentParser
import Foundation

/// The verdict of a run, or of `report`, on the kills its score counts that its own evidence doesn't back
/// (`--max-doubtful-kills`): it fails when there are more than the limit, and then exits 2
/// (`ExitCode.scoreBelowThreshold`, the status of every failed check, as #96 gives them), once every report is
/// written. A doubtful kill is one only suspect tests were recorded failing for, which no rerun alone settled
/// (`KillingTestSummary.suspectOnlyKillsNotTestedAlone`), or one whose code never ran, though its tests failed or
/// crashed (`MutationTestOutcome.unprovenKillWarning`); a kill that is both counts once.
///
/// It counts what the run tested, so a run of one mutant, a shard's, a sample's and one of `--since` or
/// `--files-to-mutate` are checked too, and needs no baseline file. A run that a signal or an error stopped isn't
/// checked, as it exits for that; nor is `report` of one that didn't finish with mutants left to test, as a resume
/// tests those, then its suspect kills again alone. One stopped during those reruns, with no mutant left, is counted:
/// a resume with nothing to test reruns nothing. Merged shards' kills are each judged by their own shard's suspect
/// tests, as its run chose which to test again alone, so the merge counts none that no shard could have settled.
struct DoubtfulKillsCheck: Equatable, Sendable {
    /// How many doubtful kills the lines name, one each; summary.json's `doubtfulKills.mutants` lists them all.
    static let shownDoubtfulKills = 20

    let maxDoubtfulKills: Int
    let verdict: Verdict
    /// For `report` of a run that didn't finish, how many of its mutants have results, which the line says; nil
    /// otherwise.
    let progress: ScoreGate.Progress?

    enum Verdict: Equatable, Sendable {
        /// The doubtful kills, in the run's order.
        case checked([DoubtfulKill])
        /// The run, or its results, stopped short, so the kills aren't counted.
        case notChecked(NotChecked)
    }

    /// A kill the score counts that the run's evidence doesn't back, by its key's description and what it changes.
    struct DoubtfulKill: Equatable, Sendable {
        let mutant: String
        let before: String
        let after: String
        /// Whether only suspect tests were recorded failing for it, and no rerun alone settled it.
        let suspectOnly: Bool
        /// Whether its code never ran, though its tests failed or crashed.
        let codeNeverRan: Bool

        init(mutant: String, before: String, after: String, suspectOnly: Bool, codeNeverRan: Bool) {
            self.mutant = mutant
            self.before = before
            self.after = after
            self.suspectOnly = suspectOnly
            self.codeNeverRan = codeNeverRan
        }

        /// "Sources/X.swift:42:17 RelationalBoundary: < → <= (only suspect tests killed it)".
        var described: String {
            "\(mutant): \(before) → \(after) (\(why))"
        }

        /// Why it is doubtful: "only suspect tests killed it", "its code never ran", or both.
        var why: String {
            switch (suspectOnly, codeNeverRan) {
            case (true, true): "only suspect tests killed it, and its code never ran"
            case (true, false): "only suspect tests killed it"
            default: "its code never ran"
            }
        }
    }

    /// Why the kills aren't counted, as `ScoreGate.NotChecked` gives it.
    enum NotChecked: String, Codable, Sendable {
        /// The run stopped before it finished, by a signal or an error, and says so itself.
        case endedEarly
        /// `report` of a run that stopped on an error, which exits as the run did.
        case stoppedOnAnError
        /// `report` of shards whose merged report lacks results (`MergedShards.lacksResults`).
        case lacksResults
        /// `report` of a run that didn't finish, with mutants left to test, whose resume tests them, then its suspect
        /// kills again alone.
        case unfinished
    }

    /// The suspect tests each mutant's kill is judged by, by its key: for merged shards, those of the shard that holds
    /// it (`MergedShards.suspectTestsByMutant`).
    typealias SuspectsByMutant = [MutantKey: Set<FailedTestLine.TestIdentity>]

    /// The verdict on `outcome`'s kills, allowing `maxDoubtfulKills` doubtful ones: not checked, for the reason
    /// `unless` gives, and `progress`, that of a run that didn't finish, says. Each kill is judged by the suspects
    /// `suspectsByMutant` gives it, if given, else by those of all of `outcome`.
    init(
        maxDoubtfulKills: Int,
        judging outcome: MutationTestOutcome,
        unless notChecked: NotChecked? = nil,
        progress: ScoreGate.Progress? = nil,
        suspectsByMutant: SuspectsByMutant? = nil
    ) {
        self.init(
            maxDoubtfulKills: maxDoubtfulKills,
            verdict: notChecked.map(Verdict.notChecked)
                ?? .checked(Self.doubtfulKills(of: outcome, suspectsByMutant: suspectsByMutant)),
            progress: notChecked == .unfinished ? progress : nil
        )
    }

    init(maxDoubtfulKills: Int, verdict: Verdict, progress: ScoreGate.Progress? = nil) {
        self.maxDoubtfulKills = maxDoubtfulKills
        self.verdict = verdict
        self.progress = progress
    }

    /// `outcome`'s doubtful kills, in its order: each kill only its suspect tests (`KillingTestSummary`) were recorded
    /// failing for that this run didn't test again alone, as one past `suspectKillReruns`, a reused one, or one whose
    /// rerun timed out or failed to build; and each kill or crash whose code never ran (`Mutation.activated`). A kill's
    /// suspect tests are those `suspectsByMutant` gives it, when given, as the shard that tested it judged them; else
    /// those of all of `outcome`.
    static func doubtfulKills(
        of outcome: MutationTestOutcome,
        suspectsByMutant: SuspectsByMutant? = nil
    ) -> [DoubtfulKill] {
        let whole = suspectsByMutant != nil ? [] : KillingTestSummary(
            of: outcome.mutations,
            controlRuns: outcome.controlRuns,
            thresholds: outcome.suspectTestThresholds
        )?.suspectIdentities ?? []
        return outcome.mutations.compactMap { mutation in
            let suspects = suspectsByMutant.map { byMutant in mutation.key.flatMap { byMutant[$0] } ?? [] } ?? whole
            let suspectOnly = KillingTestSummary.isSuspectOnlyKill(mutation, suspects: suspects)
                && !mutation.wasTestedAlone
            let codeNeverRan = [.failed, .runtimeError].contains(mutation.testSuiteOutcome)
                && mutation.activated == false
            guard suspectOnly || codeNeverRan else { return nil }
            return DoubtfulKill(
                mutant: mutation.key?.description ?? "\(mutation.relativePath):\(mutation.point.position.line):"
                    + "\(mutation.point.position.column) \(mutation.point.mutationOperatorId.rawValue)",
                before: mutation.snapshot.before,
                after: mutation.snapshot.after,
                suspectOnly: suspectOnly,
                codeNeverRan: codeNeverRan
            )
        }
    }

    /// The doubtful kills; empty when they aren't counted.
    var doubtfulKills: [DoubtfulKill] {
        guard case let .checked(kills) = verdict else { return [] }
        return kills
    }

    /// Whether there are no more doubtful kills than allowed; nil when they aren't counted.
    var passed: Bool? {
        guard case let .checked(kills) = verdict else { return nil }
        return kills.count <= maxDoubtfulKills
    }

    /// The status a command exits with for this verdict: `scoreBelowThreshold` for too many doubtful kills, and nil,
    /// so 0, otherwise.
    var exitStatus: ExitCode? {
        passed == false ? .scoreBelowThreshold : nil
    }

    /// What the run, or `report`, says of the verdict, after the score's and the survivors': "3 doubtful kills, more
    /// than the 0 allowed: 2 kills only suspect tests made, which no rerun alone settled, and 1 kill whose code never
    /// ran." No emoji, which a run adds (`consoleLines`). nil for a run that ended early, which says why itself.
    var line: String? {
        guard case let .checked(kills) = verdict else {
            guard case let .notChecked(reason) = verdict else { return nil }
            return notCheckedSentence(reason)
        }
        guard !kills.isEmpty else { return "No doubtful kills." }
        let count = kills.count == 1 ? "1 doubtful kill" : "\(kills.count) doubtful kills"
        let allowed = "the \(maxDoubtfulKills) allowed"
        let limit = kills.count > maxDoubtfulKills ? "more than \(allowed)" : "within \(allowed)"
        let suspectOnly = kills.count(where: \.suspectOnly)
        let neverRan = kills.count(where: \.codeNeverRan)
        let parts = [
            suspectOnly == 0 ? nil : (suspectOnly == 1 ? "1 kill" : "\(suspectOnly) kills")
                + " only suspect tests made, which no rerun alone settled",
            neverRan == 0 ? nil : (neverRan == 1 ? "1 kill" : "\(neverRan) kills") + " whose code never ran",
        ].compactMap { $0 }
        var sentence = "\(count), \(limit): " + parts.joined(separator: ", and ") + "."
        let both = suspectOnly + neverRan - kills.count
        if both > 0 {
            sentence += both == 1 ? " 1 of them is both." : " \(both) of them are both."
        }
        return sentence
    }

    /// `line`, then one indented line for each doubtful kill, up to `shownDoubtfulKills`, then how many more; empty
    /// when there's no line.
    var lines: [String] {
        guard let line else { return [] }
        let kills = doubtfulKills
        let hidden = kills.count - Self.shownDoubtfulKills
        return [line]
            + kills.prefix(Self.shownDoubtfulKills).map { "  " + $0.described }
            + (hidden > 0 ? ["  …and \(hidden) more"] : [])
    }

    /// What a run prints of the verdict: `lines`, the first with ✅ when it passes, ❌ when there are too many
    /// doubtful kills, and ⚠️ when they aren't counted. Empty when there's no line.
    var consoleLines: [String] {
        let lines = lines
        guard let line = lines.first else { return [] }
        let emoji = switch passed {
        case .some(true): "✅"
        case .some(false): "❌"
        case .none: "⚠️"
        }
        return ["\(emoji) \(line)"] + lines.dropFirst()
    }

    /// Why the kills aren't counted; nil for a run that ended early.
    private func notCheckedSentence(_ reason: NotChecked) -> String? {
        switch reason {
        case .stoppedOnAnError:
            return "Doubtful kills aren't counted: the run stopped on an error."

        case .lacksResults:
            return "Doubtful kills aren't counted: the merged report lacks results."

        case .unfinished:
            let results = progress.map { "only \($0.results) of \($0.discovered) mutants have results, as " } ?? ""
            return "Doubtful kills aren't counted: \(results)the run didn't finish. --resume tests the rest, then the "
                + "kills only suspect tests made again alone."

        case .endedEarly:
            return nil
        }
    }

    /// `--max-doubtful-kills`' value, a whole number, 0 or more; nil for anything else.
    static func allowed(_ text: String) -> Int? {
        NewSurvivorsCheck.allowed(text)
    }
}
