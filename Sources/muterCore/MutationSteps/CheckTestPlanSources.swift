import Foundation

/// Checks the test plan against the project's own files, never its copy, which may have been fixed by hand on purpose
/// and which `CheckMutantSwitches` checks. It reads nothing in the copy, so it runs before `LockMutatedProject`.
///
/// The plan records the project's files as they were when it was made. A run in a folder that holds none of the files
/// the plan mutates, nor any other file the plan recorded in the folders at the top of the project that hold them, as
/// `Sources`, is refused: it isn't that project, and the plan's copy is named from the project. A file at the top, as
/// `Package.swift` or `README.md`, is in most projects, so it doesn't tell. In the project, a file the plan mutates
/// that was renamed or removed is a change like any other. A run of a plan whose mutated files changed since is
/// refused, unless `--plan-ignoring` lets the change through: the copy holds them as they were, so its mutants' places
/// would describe code that is no longer there. A file with mutants that is a symbolic link counts as changed when
/// what its link's file holds changed. Only the files of the mutants to be tested count. A change to any other file
/// is only said, as the copy is tested as it is; one to a file with the plan's other mutants, which `--mutant` leaves
/// out, is said apart from one to a file the plan doesn't mutate. A plan that doesn't record the project's files, as
/// one in format 0 doesn't, isn't checked.
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
        let tested = Set(state.mutationMapping.map { RepoRelativePath.of($0.filePath, under: copy) })
            .filter { !$0.hasPrefix("/") }
        let planned = plan.mutatedPaths
        let isInTheProject = { (path: String) in
            FileManager.default.fileExists(atPath: project.appendingPathComponent(path).path)
        }
        // Before the project is fingerprinted, which in some other folder could list a great many files.
        let folders = Set(planned.compactMap(Self.topFolder(of:)))
        let beside = sources.files.keys.lazy.filter { Self.topFolder(of: $0).map(folders.contains) ?? false }
        if !planned.isEmpty, !planned.contains(where: isInTheProject), !beside.contains(where: isInTheProject) {
            throw TestPlanRefused(
                path: plan.path,
                reason: .notThisProject(
                    folder: project.path,
                    files: planned.count,
                    mutatedProject: RelativePath.from(project, to: copy)
                )
            )
        }

        let tree = await ProjectTree.fingerprint(
            listingIn: project,
            hashingIn: project,
            // The plan itself, wherever in the project it is, as well as what the run and the plan's own run left out.
            excluding: ProjectTree.excludedPaths(of: state, under: project)
                + sources.excluded
                + ProjectTree.relativePaths([plan.path], under: project),
            list: listProjectFiles
        )
        // A git that stopping the run killed reads as no repository, and the walk in its place lists what git ignores.
        try Task.checkCancellation()

        let changes = Self.changes(of: tree, since: sources, linkedFiles: plan.linkedFiles ?? [:], in: project)
        let split = changes.partition(by: state.runOptions.planIgnoring)
        let refusing = split.unwaived.filter { tested.contains($0.path) }
        guard refusing.isEmpty else {
            throw TestPlanRefused(path: plan.path, reason: .sourcesChanged(refusing))
        }
        let others = changes.filter { !tested.contains($0.path) && !planned.contains($0.path) }
        if !others.isEmpty {
            events.send(.testPlanSourcesDiffer(others))
        }
        let untested = changes.filter { !tested.contains($0.path) && planned.contains($0.path) }
        if !untested.isEmpty {
            events.send(.testPlanUntestedFilesChanged(untested))
        }
        let waived = split.waived.map(\.path).filter(tested.contains)
        if !waived.isEmpty {
            events.send(.testPlanChangesWaived(waived))
        }
        return []
    }

    /// The folder at the top of the project that `path` is in, as `Sources`; nil for a file at the top.
    private static func topFolder(of path: String) -> String? {
        let components = path.split(separator: "/", maxSplits: 1)
        return components.count == 2 ? String(components[0]) : nil
    }

    /// `tree`'s changes since `sources`, sorted by path, with each of `linkedFiles`, a file with mutants that is a
    /// symbolic link, as changed when what its link's file holds now in `project` isn't what it held, and as removed
    /// when it can't be read. `tree` records only where such a link points, which is its change when it points
    /// elsewhere.
    private static func changes(
        of tree: ProjectTree,
        since sources: ProjectTree,
        linkedFiles: [String: String],
        in project: URL
    ) -> [ProjectTree.FileChange] {
        let changes = tree.changes(since: sources)
        let changed = Set(changes.map(\.path))
        let linked = linkedFiles.keys.sorted().compactMap { path -> ProjectTree.FileChange? in
            guard !changed.contains(path) else { return nil }
            switch FileDigest.sha256(of: project.appendingPathComponent(path)) {
            case linkedFiles[path]:
                return nil

            case nil:
                return ProjectTree.FileChange(path: path, kind: .removed)

            default:
                return ProjectTree.FileChange(path: path, kind: .changed)
            }
        }
        return (changes + linked).sorted { $0.path < $1.path }
    }
}
