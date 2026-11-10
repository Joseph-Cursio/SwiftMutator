import Foundation

extension MutantResult {
    /// The record of `finished`, the run of `schema`'s mutant, whose log showed `failures` failing
    /// (`failedTests(of:ignoring:)`).
    init(
        key: MutantKey,
        schema: MutationSchema,
        finished: FinishedRun,
        failures: FailedTestLine.FailedTests?,
        session: Int,
        finishedAt: Date,
        log: String?,
        fileSHA256: String? = nil,
        rerun: Rerun? = nil
    ) {
        let run = finished.run
        self.init(
            session: session,
            path: key.path,
            line: key.line,
            column: key.column,
            occurrence: key.occurrence,
            utf8Offset: schema.position.utf8Offset,
            mutationOperatorId: schema.mutationOperatorId,
            switchID: schema.id,
            snapshot: schema.snapshot,
            outcome: run.outcome,
            endedBy: run.ending,
            exitStatus: run.ending == .exited ? run.exitStatus : nil,
            durationSeconds: Self.recordedSeconds(finished.seconds),
            worker: finished.worker,
            finishedAt: finishedAt,
            killedBy: failures?.tests,
            failedTestCount: failures?.total,
            firstFailedTestLine: failures?.firstLine,
            log: log,
            fileSHA256: fileSHA256,
            rerun: rerun
        )
        activated = run.activated
    }

    /// The tests a killed, crashed or timed-out run's log shows failing, but for `lookalikes`: those a passing
    /// baseline's lines showed failing, as such lines are the tests' own text, printed whatever the mutant. nil for
    /// any other run.
    static func failedTests(
        of run: TestRun,
        ignoring lookalikes: Set<FailedTestLine.TestIdentity> = []
    ) -> FailedTestLine.FailedTests? {
        guard [.failed, .runtimeError, .timeout].contains(run.outcome) else { return nil }
        return FailedTestLine.failedTests(inLog: run.testLog, ignoring: lookalikes)
    }
}
