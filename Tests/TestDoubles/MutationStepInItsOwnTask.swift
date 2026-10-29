@testable import muterCore

extension MutationStep {
    /// Runs the step in a task of its own and waits for it, so a test that cancels it mid-run doesn't cancel itself.
    func runInItsOwnTask(with state: AnyMutationTestState) async -> Result<[MutationTestState.Change], Error> {
        let run = StepRun(step: self, state: state)
        return await Task { try await run.step.run(with: run.state) }.result
    }
}

/// A step and the state it changes, neither of them Sendable, handed to the task that runs them. The test waits for
/// that task and does nothing meanwhile, so the two are never used from two tasks at once, which the compiler can't
/// see.
private struct StepRun: @unchecked Sendable {
    let step: MutationStep
    let state: AnyMutationTestState
}
