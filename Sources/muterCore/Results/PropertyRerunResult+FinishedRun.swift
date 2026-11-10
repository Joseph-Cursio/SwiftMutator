import Foundation

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
