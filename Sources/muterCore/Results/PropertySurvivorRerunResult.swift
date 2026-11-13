import Foundation

/// A property survivor rerun's line in the results file: a survivor tested again with only the property tests
/// `propertyTestFilter` selects, up to `runs` times, stopping at the first run that didn't pass
/// (`PropertySurvivorReruns`). Its fields are that last run's: the run that failed, the one that settled nothing, or
/// the `runs`th, which passed. It follows the mutant's own line, which it never replaces, so the survivor stays a
/// survivor in the score: the reports read it to tell "a property failed on a later run" from "every property passed".
/// A later `mutant` line of the same key, a new result, sets it aside. A reader that doesn't know the kind skips the
/// line.
struct PropertySurvivorRerunResult: Codable, Equatable {
    // swiftlint:disable:next unused_declaration - results file key; Codable writes it
    var kind = "propertySurvivorRerun"
    let session: Int
    /// The mutant's key's fields (`MutantKey`), as its `mutant` line records them.
    let path: String
    let line: Int
    let column: Int
    let occurrence: Int
    let mutationOperatorId: MutationOperator.Id
    /// Which of the runs this is, from 1: the last one made.
    let run: Int
    /// How many runs the survivor was to be given, `propertySurvivorReruns` when they started.
    let runs: Int
    /// How the property tests came out with the mutant on in run `run`: `failed` or `runtimeError` is a property
    /// that tells the mutant apart, `passed` (with `run` equal to `runs`) a survivor every run passed.
    let outcome: TestSuiteOutcome
    let endedBy: TestRun.Ending
    /// Only for an `exited` run: its exit code, or the signal that ended it.
    let exitStatus: Int32? // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// From launch to classification, to the millisecond, of run `run`.
    let durationSeconds: Double // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// Where run `run` ran, as a mutant's `worker` says.
    let worker: Int // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    let finishedAt: Date
    /// The tests its log shows failing, as a mutant's `killedBy` names them.
    let killedBy: [FailedTestLine.FailedTest]?
    /// How many distinct tests its log shows failing, uncapped.
    let failedTestCount: Int?
    /// The first line that shows one, without colour codes, capped.
    let firstFailedTestLine: String? // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// Run `run`'s kept log's file name in the session's `logDirectory`, when it was kept.
    let log: String?

    var key: MutantKey {
        MutantKey(
            path: path,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column,
            occurrence: occurrence
        )
    }
}

extension MutationTestOutcome {
    /// A survivor's property reruns, as the reports read them (`PropertySurvivorRerunResult`).
    struct PropertySurvivorRerun: Codable, Equatable {
        /// How the last run came out.
        let outcome: TestSuiteOutcome
        /// The last run's number, from 1.
        let run: Int
        /// How many runs it was to be given.
        let runs: Int
        /// The tests the last run recorded failing.
        let killingTests: KillingTests?

        /// The run on which a property test told the mutant apart, failing or crashing; nil when none did.
        var failedOnRun: Int? {
            outcome == .failed || outcome == .runtimeError ? run : nil
        }

        /// Whether every one of the `runs` passed: no property tells the mutant apart in that many samples.
        var passedEveryRun: Bool {
            outcome == .passed && run >= runs
        }
    }
}
