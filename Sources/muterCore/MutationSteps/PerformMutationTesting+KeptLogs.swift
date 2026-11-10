/// Which mutants' logs a session keeps, and so which of its results lines name one (`MutationTestLog.isKept`).
extension PerformMutationTesting {
    /// The name `finished`'s log is kept under, `log`, or nil when it keeps none, as its line then names none: a kill
    /// by a failed test that `failures`, the tests its line names, include, unless `configuration` keeps every log.
    /// The run of the one mutant `--mutant` tests always keeps its log, which the console names.
    static func keptLogName(
        _ log: String,
        of finished: FinishedRun,
        failures: FailedTestLine.FailedTests?,
        configuration: MuterConfiguration,
        state: AnyMutationTestState
    ) -> String? {
        // A kill whose code didn't run keeps its log: it is what the warning about it has to show.
        let keeps = state.selectedMutant != nil || finished.run.activated == .didNotRun || MutationTestLog.isKept(
            outcome: finished.run.outcome, killedBy: failures?.tests, keepingAll: configuration.keepsAllLogs
        )
        return keeps ? log : nil
    }

    /// Whether a session that reuses `result`, a result of an earlier run, keeps a log for it, by the rule its own
    /// mutants' runs go by, so a reuse doesn't carry an earlier run's kills' logs forward.
    static func keepsLog(of result: MutantResult, reusedBy state: AnyMutationTestState) -> Bool {
        result.activated == .didNotRun || MutationTestLog.isKept(
            outcome: result.outcome, killedBy: result.killedBy, keepingAll: state.muterConfiguration.keepsAllLogs
        )
    }

    /// Whether a reuse copies any of `plan`'s kept results onto a line that names no log, which only a format-4 reader
    /// reads: one recorded with no log, or one it keeps none for (`keepsLog(of:reusedBy:)`). Never for a resume,
    /// which copies no result.
    static func copiesLinesWithoutLogs(_ plan: ResumePlan, state: AnyMutationTestState) -> Bool {
        guard state.resumeState?.isReuse == true else { return false }
        return plan.reused.values.contains { $0.log == nil || !keepsLog(of: $0, reusedBy: state) }
    }
}
