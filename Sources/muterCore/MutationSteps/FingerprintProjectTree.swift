import Foundation

/// Records the project's files, each one's SHA-256 by its path, so a later run can tell whether a result still holds.
/// They are listed from the project, which a repository that ignores SwiftMutator's copies still lists, and hashed in
/// the copy, as it was tested. It runs right after the copy, before discovery rewrites the files it mutates.
struct FingerprintProjectTree: MutationStep {
    @Dependency(\.listProjectFiles)
    private var listProjectFiles: ProjectFileListing

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let tree = ProjectTree.fingerprint(
            listingIn: state.projectDirectoryURL,
            hashingIn: state.mutatedProjectDirectoryURL,
            excluding: ProjectTree.reportPaths(state.runOptions, under: state.projectDirectoryURL),
            list: listProjectFiles
        )
        // A git that stopping the run killed reads as no repository, and the walk in its place lists what git ignores.
        try Task.checkCancellation()
        return [.projectTreeFingerprinted(tree)]
    }
}
