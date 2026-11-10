import Foundation

/// Records the project's files, each one's SHA-256 by its path, so a later run can tell whether a result still holds.
/// They are listed from the project, which a repository that ignores SwiftMutator's copies still lists, and hashed in
/// the copy, as it was tested. It runs right after the copy, before discovery rewrites the files it mutates.
///
/// A run that tests a test plan copies nothing: it fingerprints the plan's copy once it is locked and its switches
/// checked, as it is tested, rewritten and with any fix made by hand. That is what its results file records, and what
/// each mutant's result is judged by. The plan file is left out, wherever in the project it is. A file with mutants
/// that differs from what `mutate-without-running` left in the copy is said, so a fix by hand is seen to be tested;
/// it is never refused, as `CheckMutantSwitches` checks the copy. A resumed run of a plan compares the copy with the
/// one its last session tested, which `LoadResumeState` left to it: a change, as a fix by hand between sessions, is
/// refused unless `--resume-ignoring` lets it through. So that only the copy's own changes count, the copy's files are
/// the ones the plan and the last session recorded, not the project's as it lists them now, and none of the folders
/// SwiftMutator's build writes in the copy is fingerprinted. A `Package.resolved` the project didn't have when the plan
/// was made, which the copy's build writes, is only said when it changes.
///
/// A resumed run compares the copy with the last session's files too. `LoadResumeState` compared the project before the
/// copy, so this only finds what changed while it was copied, and hands on the changes `--resume-ignoring` let through.
/// A run that reuses an earlier run's results instead hands on every change since each of that run's sessions, split by
/// what it can make wrong (`ReuseChanges`), which decides which of the session's results it keeps: a session that
/// resumed the run may have let changes through that its earlier results weren't tested with.
///
/// It also says what the build uses from outside the project, which gets no mutants (`OutsideProjectCode`). Every run
/// fingerprints once, so the notice comes once, from the listing the fingerprint made. The local packages among it are
/// fingerprinted, but the projects a workspace references outside the project aren't: adding their files would make
/// every earlier results file of such a project read as changed, and refuse its `--resume`. It warns, also once, of
/// code inside the project that a workspace or manifest names by an absolute path, which the copy builds unmutated.
struct FingerprintProjectTree: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.listProjectFiles)
    private var listProjectFiles: ProjectFileListing

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let lastSession = state.resumeState?.lastHeader.project
        let copyListing = state.testPlan.flatMap { Self.copyListing(of: $0, lastSession: lastSession) }
        let fingerprinting = await ProjectTree.fingerprinting(
            listingIn: state.projectDirectoryURL,
            hashingIn: state.mutatedProjectDirectoryURL,
            // The last session's too: its report may still be in the project, under another name.
            excluding: ProjectTree.excludedPaths(of: state, under: state.projectDirectoryURL)
                + (lastSession?.excluded ?? [])
                + ProjectTree.relativePaths([state.testPlan?.path], under: state.projectDirectoryURL),
            list: { [listProjectFiles, project = state.projectDirectoryURL] directory in
                guard let copyListing, directory == project else { return await listProjectFiles(directory) }
                return copyListing.paths
            },
            pruning: state.testPlan == nil
                ? []
                : Self.foldersWritten(in: state.mutatedProjectDirectoryURL, by: state.muterConfiguration)
        )
        // A git that stopping the run killed reads as no repository, and the walk in its place lists what git ignores.
        try Task.checkCancellation()
        let fingerprinted = fingerprinting.tree
        let outside = OutsideProjectCode.paths(
            in: state.projectDirectoryURL,
            listed: fingerprinting.paths,
            localPackages: fingerprinting.localPackages
        )
        if !outside.isEmpty {
            events.send(.codeOutsideTheProjectBuilt(outside))
        }
        let namedByAbsolutePath = OutsideProjectCode.namedByAbsolutePath(
            in: state.projectDirectoryURL,
            listed: fingerprinting.paths
        )
        if !namedByAbsolutePath.isEmpty {
            events.send(.projectCodeNamedByAbsolutePath(namedByAbsolutePath))
        }
        let tree = copyListing.map { listing in
            ProjectTree(
                listedBy: listing.listedBy,
                files: fingerprinted.files,
                excluded: fingerprinted.excluded,
                treeSHA256: fingerprinted.treeSHA256
            )
        } ?? fingerprinted
        if let written = state.testPlan?.mutatedFiles {
            let edited = Self.filesEdited(in: tree, since: written)
            if !edited.isEmpty {
                events.send(.testPlanCopyEdited(edited))
            }
        }
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
        let resolved = state.testPlan?.sources.map { Self.resolutionsWritten(in: split.unwaived, since: $0) } ?? []
        let unwaived = split.unwaived.filter { !resolved.contains($0) }
        guard unwaived.isEmpty else {
            // A run of a test plan copies and removes nothing.
            let usingTestPlan = state.runOptions.isUsingTestPlan
            throw ResumeRefused(
                path: resume.path,
                reasons: [
                    usingTestPlan
                        ? .copyChanged(unwaived, copy: state.mutatedProjectDirectoryURL.path)
                        : .filesChanged(unwaived),
                ],
                beforeTheCopy: usingTestPlan
            )
        }
        if !resolved.isEmpty {
            events.send(.testPlanCopyResolutionChanged(resolved))
        }
        return [.projectTreeFingerprinted(tree), .projectChangesWaived(split.waived.map(\.path))]
    }

    /// What a run of `plan` lists in its copy, and how the paths were found: the project's files the plan recorded,
    /// with those `lastSession` recorded, so that a file removed from the project's listing since, as by `git rm` or
    /// a switch to another branch, isn't taken for one removed from the copy. Nil when neither records them, as in the
    /// first session of a plan in format 0, which lists the project. A local package outside the project is listed
    /// where it is.
    static func copyListing(
        of plan: LoadedTestPlan,
        lastSession: ProjectTree?
    ) -> (paths: [String], listedBy: ProjectTree.Listing)? {
        let trees = [plan.sources, lastSession].compactMap(\.self)
        guard let first = trees.first else { return nil }
        let paths = Set(trees.flatMap(\.files.keys)).filter { !$0.hasPrefix("../") }
        return (paths.sorted(), first.listedBy)
    }

    /// The folders SwiftMutator writes in a test plan's copy, which keeps them from one session to the next, by their
    /// paths relative to the copy: for xcodebuild, the `-derivedDataPath` it builds in, if it is in the copy, and
    /// `TestContents`, where it copies the build. Nothing for another build system.
    static func foldersWritten(in copy: URL, by configuration: MuterConfiguration) -> Set<String> {
        guard configuration.buildSystem == .xcodebuild else { return [] }
        // The build runs in the copy, so a relative path is in it.
        let derivedData = configuration.derivedDataPath
        let path = derivedData.hasPrefix("/") ? derivedData : copy.appendingPathComponent(derivedData).path
        return Set([BuildForTesting.testContentsFolder] + ProjectTree.relativePaths([path], under: copy))
    }

    /// The dependency resolution files of `changes`, the copy's since a resumed run's last session, that `sources`,
    /// the project's files when the plan was made, don't hold: `Package.resolved` at the copy's root, or in a
    /// workspace, which the copy's own build writes, as when the project ignores it.
    static func resolutionsWritten(
        in changes: [ProjectTree.FileChange],
        since sources: ProjectTree
    ) -> [ProjectTree.FileChange] {
        changes.filter { change in
            change.path.lastPathComponent == "Package.resolved"
                && ProjectTree.isAlwaysIncluded(change.path)
                && sources.files[change.path] == nil
        }
    }

    /// The files of `written`, the SHA-256 of each file with mutants as `mutate-without-running` left it in the copy,
    /// that `tree` holds otherwise, sorted. A file `tree` doesn't hold, as one outside the copy, isn't compared.
    static func filesEdited(in tree: ProjectTree, since written: [String: String]) -> [String] {
        written.compactMap { path, hash in
            guard let now = tree.files[path], now != hash else { return nil }
            return path
        }
        .sorted()
    }
}
