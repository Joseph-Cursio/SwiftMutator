import Foundation

/// Records the project's files, each one's SHA-256 by its path, so a later run can tell whether a result still holds.
/// They are listed from the project, which a repository that ignores SwiftMutator's copies still lists, and hashed in
/// the copy, as it was tested. It runs right after the copy, before discovery rewrites the files it mutates.
///
/// A resumed run compares the copy with the last session's files too. `LoadResumeState` compared the project before the
/// copy, so this only finds what changed while it was copied, and hands on the changes `--resume-ignoring` let through.
/// A run that reuses an earlier run's results instead hands on every change since each of that run's sessions, split by
/// what it can make wrong (`ReuseChanges`), which decides which of the session's results it keeps: a session that
/// resumed the run may have let changes through that its earlier results weren't tested with.
struct FingerprintProjectTree: MutationStep {
    @Dependency(\.listProjectFiles)
    private var listProjectFiles: ProjectFileListing

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let tree = await ProjectTree.fingerprint(
            listingIn: state.projectDirectoryURL,
            hashingIn: state.mutatedProjectDirectoryURL,
            // The last session's too: its report may still be in the project, under another name.
            excluding: ProjectTree.excludedPaths(state.runOptions, under: state.projectDirectoryURL)
                + (state.resumeState?.lastHeader.project?.excluded ?? []),
            list: listProjectFiles
        )
        // A git that stopping the run killed reads as no repository, and the walk in its place lists what git ignores.
        try Task.checkCancellation()
        guard let resume = state.resumeState, let recorded = resume.lastHeader.project else {
            return [.projectTreeFingerprinted(tree)]
        }
        if resume.isReuse {
            var sources: [String: String?] = [:]
            let readSource = { (path: String) -> String? in
                if let read = sources[path] {
                    return read
                }
                // A local package outside the project isn't copied: its files were hashed where they are.
                let root = path.hasPrefix("../") ? state.projectDirectoryURL : state.mutatedProjectDirectoryURL
                let read = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                sources[path] = read
                return read
            }
            var changes: [Int: ReuseChanges] = [:]
            for header in resume.recorded.headers {
                guard let sessionTree = header.project else { continue }
                changes[header.session] = ReuseChanges(
                    from: sessionTree,
                    to: tree,
                    waiving: state.runOptions.resumeIgnoring,
                    readSource: readSource
                )
            }
            let waived = Set(changes.values.flatMap(\.waived)).sorted()
            return [.projectTreeFingerprinted(tree), .projectChangesWaived(waived), .reuseChangesFound(changes)]
        }
        let split = tree.changes(since: recorded).partition(by: state.runOptions.resumeIgnoring)
        guard split.unwaived.isEmpty else {
            throw ResumeRefused(path: resume.path, reasons: [.filesChanged(split.unwaived)], beforeTheCopy: false)
        }
        return [.projectTreeFingerprinted(tree), .projectChangesWaived(split.waived.map(\.path))]
    }
}
