import Foundation

/// A control run's line in the results file: the test command with no mutant on, run among a session's mutants, on a
/// worker of theirs and under the same time limit and load, never stopped at its first failed test. A test that fails
/// in it is flaky, and the reports count a kill only such tests were recorded failing for as suspect. A reader that
/// doesn't know the kind skips the line.
struct ControlRunResult: Codable, Equatable {
    var kind = "control"
    let session: Int
    /// 1 for the session's first control run.
    let number: Int
    /// How many of the session's mutants had started before it: it starts once they have, whichever worker is free.
    let afterMutants: Int
    let outcome: TestSuiteOutcome
    let endedBy: TestRun.Ending
    /// Only for an `exited` run: its exit code, or the signal that ended it.
    let exitStatus: Int32?
    /// From launch to classification, to the millisecond.
    let durationSeconds: Double
    /// Where it ran, as a mutant's `worker` says.
    let worker: Int
    let finishedAt: Date
    /// For a run that failed, crashed or timed out: the tests its log shows failing, as a mutant's `killedBy` names
    /// them, but for the header's `failedTestLookalikes`.
    let failedTests: [FailedTestLine.FailedTest]?
    /// How many distinct tests its log shows failing, uncapped.
    let failedTestCount: Int?
    /// The first line that shows one, without colour codes, capped.
    let firstFailedTestLine: String?
    /// The kept log's file name in the session's `logDirectory`.
    let log: String
}

extension ControlRunResult {
    /// The record of `finished`, control run `number` of session `session`, started after `afterMutants` of its
    /// mutants, whose log showed `failures` failing (`MutantResult.failedTests(of:ignoring:)`).
    init(
        number: Int,
        afterMutants: Int,
        finished: FinishedRun,
        failures: FailedTestLine.FailedTests?,
        session: Int,
        finishedAt: Date,
        log: String
    ) {
        let run = finished.run
        self.init(
            session: session,
            number: number,
            afterMutants: afterMutants,
            outcome: run.outcome,
            endedBy: run.ending,
            exitStatus: run.ending == .exited ? run.exitStatus : nil,
            durationSeconds: (finished.seconds * 1000).rounded() / 1000,
            worker: finished.worker,
            finishedAt: finishedAt,
            failedTests: failures?.tests,
            failedTestCount: failures?.count,
            firstFailedTestLine: failures?.firstLine,
            log: log
        )
    }

    /// "control run 2.log": the name of control run `number`'s kept log.
    static func logName(of number: Int) -> String {
        "control run \(number).log"
    }
}
