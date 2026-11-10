import Foundation

/// A property rerun's line in the results file: a killed mutant tested again with only the property tests
/// `propertyTestFilter` selects, as its kill's recorded tests include none (`PropertyReruns`). It follows the mutant's
/// own line, which it never replaces: the reports read it to tell "only by examples" from "by both". A later `mutant`
/// line of the same key, a new result, sets it aside. A reader that doesn't know the kind skips the line.
struct PropertyRerunResult: Codable, Equatable {
    var kind = "propertyRerun"
    let session: Int
    /// The mutant's key's fields (`MutantKey`), as its `mutant` line records them.
    let path: String
    let line: Int
    let column: Int
    let occurrence: Int
    let mutationOperatorId: MutationOperator.Id
    /// How the property tests came out with the mutant on: `failed` or `runtimeError` is a kill by a property too.
    let outcome: TestSuiteOutcome
    let endedBy: TestRun.Ending
    /// Only for an `exited` run: its exit code, or the signal that ended it.
    let exitStatus: Int32?
    /// From launch to classification, to the millisecond.
    let durationSeconds: Double
    /// Where it ran, as a mutant's `worker` says.
    let worker: Int
    let finishedAt: Date
    /// The tests its log shows failing, as a mutant's `killedBy` names them.
    let killedBy: [FailedTestLine.FailedTest]?
    /// How many distinct tests its log shows failing, uncapped.
    let failedTestCount: Int?
    /// The first line that shows one, without colour codes, capped.
    let firstFailedTestLine: String?
    /// The kept log's file name in the session's `logDirectory`, when it was kept (`PropertyReruns.keepsLog`).
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

extension PropertyRerunResult {
    /// The record of `finished`, the property tests' run with `key`'s mutant on, in session `session`, whose log showed
    /// `failures` failing (`MutantResult.failedTests(of:ignoring:)`).
    init(
        key: MutantKey,
        finished: FinishedRun,
        failures: FailedTestLine.FailedTests?,
        session: Int,
        finishedAt: Date,
        log: String?
    ) {
        let run = finished.run
        self.init(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            mutationOperatorId: key.mutationOperatorId,
            outcome: run.outcome,
            endedBy: run.ending,
            exitStatus: run.ending == .exited ? run.exitStatus : nil,
            durationSeconds: MutantResult.recordedSeconds(finished.seconds),
            worker: finished.worker,
            finishedAt: finishedAt,
            killedBy: failures?.tests,
            failedTestCount: failures?.total,
            firstFailedTestLine: failures?.firstLine,
            log: log
        )
    }

    /// What the reports read of it.
    var rerun: MutationTestOutcome.PropertyRerun {
        MutationTestOutcome.PropertyRerun(
            outcome: outcome,
            killingTests: .init(killedBy: killedBy, failedTestCount: failedTestCount, endedBy: endedBy)
        )
    }
}

extension MutationTestOutcome {
    /// A killed mutant's property rerun, as the reports read it (`PropertyRerunResult`).
    struct PropertyRerun: Codable, Equatable {
        let outcome: TestSuiteOutcome
        /// The tests it recorded failing.
        let killingTests: KillingTests?

        /// Whether a property test killed the mutant too: it failed, or crashed.
        var killed: Bool {
            outcome == .failed || outcome == .runtimeError
        }
    }
}
