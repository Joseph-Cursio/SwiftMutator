import Foundation

/// Checks the test plan against the project's own files, never its copy, which may have been fixed by hand on purpose
/// and which `CheckMutantSwitches` checks. It reads nothing in the copy, so it runs before `LockMutatedProject`.
///
/// The plan records the project's files as they were when it was made. A run in a folder that holds none of the files
/// the plan mutates is refused: it isn't that project, and the plan's copy is named from the project. So is a run of a
/// plan whose mutated files changed since, unless `--plan-ignoring` lets the change through: the copy holds them as
/// they were, so its mutants' places would describe code that is no longer there. Only the files of the mutants to be
/// tested count. A change to any other file is only said, as the copy is tested as it is. A plan that doesn't record
/// the project's files, as one in format 0 doesn't, isn't checked.
struct CheckTestPlanSources: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.listProjectFiles)
    private var listProjectFiles: ProjectFileListing

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let plan = state.testPlan else { return [] }
        guard let sources = plan.sources else {
            events.send(.testPlanSourcesUnchecked)
            return []
        }
        let project = state.projectDirectoryURL
        let copy = state.mutatedProjectDirectoryURL
        // A file outside the copy keeps its absolute path, and isn't the project's.
        let mutated = Set(state.mutationMapping.map { RepoRelativePath.of($0.filePath, under: copy) })
            .filter { !$0.hasPrefix("/") }
        let isInTheProject = { (path: String) in
            FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path)
        }
        // Before the project is fingerprinted, which in some other folder could list a great many files.
        if !mutated.isEmpty, !mutated.contains(where: isInTheProject) {
            throw TestPlanRefused(
                path: plan.path,
                reason: .notThisProject(
                    folder: project.path,
                    files: mutated.count,
                    mutatedProject: RelativePath.from(project, to: copy)
                )
            )
        }

        let tree = await ProjectTree.fingerprint(
            listingIn: project,
            hashingIn: project,
            // The plan itself, wherever in the project it is, as well as what the run and the plan's own run left out.
            excluding: ProjectTree.excludedPaths(state.runOptions, under: project)
                + sources.excluded
                + ProjectTree.relativePaths([plan.path], under: project),
            list: listProjectFiles
        )
        // A git that stopping the run killed reads as no repository, and the walk in its place lists what git ignores.
        try Task.checkCancellation()

        let changes = tree.changes(since: sources)
        let split = changes.partition(by: state.runOptions.planIgnoring)
        let refusing = split.unwaived.filter { mutated.contains($0.path) }
        guard refusing.isEmpty else {
            throw TestPlanRefused(path: plan.path, reason: .sourcesChanged(refusing))
        }
        let others = changes.filter { !mutated.contains($0.path) }
        if !others.isEmpty {
            events.send(.testPlanSourcesDiffer(others))
        }
        let waived = split.waived.map(\.path).filter(mutated.contains)
        if !waived.isEmpty {
            events.send(.testPlanChangesWaived(waived))
        }
        return []
    }
}
