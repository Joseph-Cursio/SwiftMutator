import Foundation

/// Names the mutated project, beside the project: `<project>_mutated`, or `<project>_mutant` for a run of one mutant
/// (`--mutant`). That run's copy, its lock and its clean-up are its own, so it never removes a test plan's copy, which
/// may have been fixed by hand, and it can run while another run of the project tests.
struct CreateMutatedProjectDirectoryURL: MutationStep {
    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        let destinationPath = destinationPath(
            with: state.projectDirectoryURL,
            suffix: state.runOptions.mutant == nil ? "_mutated" : "_mutant"
        )

        return [
            .tempDirectoryUrlCreated(URL(fileURLWithPath: destinationPath))
        ]
    }

    private func destinationPath(
        with projectDirectoryURL: URL,
        suffix: String
    ) -> String {
        let lastComponent = projectDirectoryURL.lastPathComponent
        let modifiedDirectory = projectDirectoryURL.deletingLastPathComponent()
        let destination = modifiedDirectory.appendingPathComponent(lastComponent + suffix)
        return destination.path
    }
}
