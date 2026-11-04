import Foundation

/// Names the mutated project, beside the project: `<project>_mutated.noindex`, or `<project>_mutant.noindex` for a run
/// of one mutant (`--mutant`), as `MutatedProjectNames.copy(of:forOneMutant:)` gives them. That run's copy, its lock
/// and its clean-up are its own, so it never removes a test plan's copy, which may have been fixed by hand, and it can
/// run while another run of the project tests.
struct CreateMutatedProjectDirectoryURL: MutationStep {
    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        let copy = MutatedProjectNames.copy(
            of: state.projectDirectoryURL,
            forOneMutant: state.runOptions.mutant != nil
        )
        return [.tempDirectoryUrlCreated(URL(fileURLWithPath: copy.path))]
    }
}
