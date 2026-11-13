import Foundation

extension PropertySurvivorRerunResult {
    /// The record of `finished`, run `run` of `runs` of the property tests with `key`'s mutant on, in session
    /// `session`, whose log showed `failures` failing (`MutantResult.failedTests(of:ignoring:)`).
    init(
        key: MutantKey,
        finished: FinishedRun,
        run: Int,
        of runs: Int,
        failures: FailedTestLine.FailedTests?,
        session: Int,
        finishedAt: Date,
        log: String?
    ) {
        let testRun = finished.run
        self.init(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            mutationOperatorId: key.mutationOperatorId,
            run: run,
            runs: runs,
            outcome: testRun.outcome,
            endedBy: testRun.ending,
            exitStatus: testRun.ending == .exited ? testRun.exitStatus : nil,
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
    var rerun: MutationTestOutcome.PropertySurvivorRerun {
        MutationTestOutcome.PropertySurvivorRerun(
            outcome: outcome,
            run: run,
            runs: runs,
            killingTests: .init(killedBy: killedBy, failedTestCount: failedTestCount, endedBy: endedBy)
        )
    }
}
