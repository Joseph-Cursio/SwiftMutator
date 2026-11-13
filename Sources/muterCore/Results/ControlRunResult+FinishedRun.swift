import Foundation

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
            durationSeconds: (finished.seconds * 1_000).rounded() / 1_000,
            worker: finished.worker,
            finishedAt: finishedAt,
            failedTests: failures?.tests,
            failedTestCount: failures?.total,
            firstFailedTestLine: failures?.firstLine,
            log: log
        )
    }

    /// "control run 2.log": the name of control run `number`'s kept log.
    static func logName(of number: Int) -> String {
        "control run \(number).log"
    }
}
