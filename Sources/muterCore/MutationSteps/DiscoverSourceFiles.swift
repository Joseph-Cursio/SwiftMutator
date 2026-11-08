import Foundation
import Pathos

/// A `--files-to-mutate` entry that leaves no file to mutate, and why.
struct UnmatchedFilesToMutate: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// No Swift file is there.
        case noSwiftFile
        /// Each Swift file it names is outside the project.
        case outsideTheProject
        /// The excludes leave out each Swift file it names, and an entry that starts with `!` could keep one.
        case excluded
        /// Each Swift file it names is a manifest, or in a build folder, which no entry can keep.
        case neverMutated
        /// The coverage filter leaves out each one the excludes leave in.
        case withoutCoverage
    }

    let entry: String
    let reason: Reason
}

struct DiscoverSourceFiles: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.process)
    private var process: ProcessFactory
    @Dependency(\.listProjectFiles)
    private var listProjectFiles: ProjectFileListing

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        events.send(.sourceFileDiscoveryStarted)

        var listed = state.candidatePaths
        if listed == nil, state.filesToMutate.isEmpty {
            listed = try await candidatePaths(in: state)
        }
        let sourceFileCandidates: [FilePath]
        let uncovered: [FilePath]
        if state.filesToMutate.isEmpty {
            (sourceFileCandidates, uncovered) = discoverSourceFiles(
                among: (listed ?? []).filter(isChosen(by: state)),
                in: state
            )
        } else {
            let (files, uncoveredFiles, unmatched) = filesToMutate(in: state)
            if !unmatched.isEmpty {
                events.send(.filesToMutateUnmatched(unmatched))
            }
            sourceFileCandidates = files
            uncovered = uncoveredFiles
        }

        let failure: MuterError = state.filesToMutate.isEmpty
            ? .noSourceFilesDiscovered
            : .noSourceFilesOnExclusiveList

        events.send(.sourceFileDiscoveryFinished(sourceFileCandidates))

        // With `--baseline`, the mutants of a file coverage leaves out are compared, so a run with no file to mutate
        // but such a file goes on to find them: a change that adds only a file no test reaches has new survivors.
        // Discovery ends it then, as it does when no mutant is left (`DiscoverMutationPoints`).
        let comparesUncovered = !uncovered.isEmpty && Self.comparesUncoveredMutants(state)
        if let selection = state.changeSelection {
            try check(
                sourceFileCandidates,
                andUncovered: uncovered,
                against: selection,
                comparesUncovered: comparesUncovered,
                in: state
            )
        }
        if !sourceFileCandidates.isEmpty || comparesUncovered {
            return [.sourceFileCandidatesDiscovered(sourceFileCandidates)]
                + (uncovered.isEmpty ? [] : [.uncoveredSourceFilesDiscovered(uncovered)])
        } else {
            throw failure
        }
    }

    /// Whether a run compares the mutants of code no test ran: with `--baseline`, but for a run of one mutant, which
    /// compares no survivors.
    static func comparesUncoveredMutants(_ state: AnyMutationTestState) -> Bool {
        state.runOptions.baseline != nil && state.runOptions.mutant == nil
    }

    /// Why `--since` leaves nothing to mutate when it leaves no file to: discovery leaves out each changed file that
    /// the excludes don't.
    static func noFileDiscovered(_ selection: ChangeSelection, in state: AnyMutationTestState) -> NothingToMutate {
        let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
        let count = selection.files.filter { !isExcluded($0.path) }.count
        return NothingToMutate(reason: .noFileDiscovered(count: count), selection: selection)
    }
}

private extension DiscoverSourceFiles {
    /// With `--since`, whether a path in the project is one of the files it chose; without, every path is.
    func isChosen(by state: AnyMutationTestState) -> (FilePath) -> Bool {
        guard let selection = state.changeSelection else { return { _ in true } }
        let chosen = Set(selection.files.map(\.path))
        return { chosen.contains($0.precomposedStringWithCanonicalMapping) }
    }

    /// That `--since` left a file to mutate, or one coverage leaves out whose mutants the run compares
    /// (`comparesUncovered`), and that each is as git compared it, and each file coverage leaves out, whose mutants
    /// are counted as not covered: the copy is made after, and the lines of a file changed in between would be wrong.
    func check(
        _ candidates: [FilePath],
        andUncovered uncovered: [FilePath],
        against selection: ChangeSelection,
        comparesUncovered: Bool,
        in state: AnyMutationTestState
    ) throws {
        guard !candidates.isEmpty || comparesUncovered else {
            throw Self.noFileDiscovered(selection, in: state)
        }
        for candidate in candidates + uncovered {
            let path = RepoRelativePath.of(candidate, under: state.mutatedProjectDirectoryURL)
                .precomposedStringWithCanonicalMapping
            guard let file = selection.file(at: path) else { continue }
            if let copied = state.projectTree?.files[path], copied != file.sha256 {
                throw ChangeSelectionError.changedDuringTheRun(path: path)
            }
        }
    }
}

extension DiscoverSourceFiles {
    /// The paths in the mutated project, relative to it, that discovery picks from. For a SwiftPM project, the Swift
    /// files its targets compile, and those of the local packages in it that it depends on, as `swift package describe`
    /// gives them. Otherwise, or if that fails, every path in the project that isn't hidden or ignored.
    func candidatePaths(in state: AnyMutationTestState) async throws -> [FilePath] {
        let rootPath = state.mutatedProjectDirectoryURL.path
        if state.muterConfiguration.buildSystem == .swift {
            switch await packageSourceFiles(inProjectAt: rootPath, testedBy: state.muterConfiguration) {
            case let .success(files):
                return files
            case let .failure(failure):
                // A describe that stopping the run killed reads as failed, and no warning is due.
                try Task.checkCancellation()
                events.send(.packageSourceFilesUnavailable(reason: failure.reason))
            }
        }

        return await pathsNotHiddenOrIgnored(in: rootPath, listedIn: state.projectDirectoryURL)
    }

}

private extension DiscoverSourceFiles {
    /// `SwiftPackageSources.files`, run in the mutated project at `rootPath`, as the coverage run and the tests are:
    /// a relative `executable` or `--package-path` is relative to it.
    private func packageSourceFiles(
        inProjectAt rootPath: FilePath,
        testedBy configuration: MuterConfiguration
    ) async -> Result<[FilePath], SwiftPackageSources.Failure> {
        let currentDirectoryPath = fileManager.currentDirectoryPath
        fileManager.changeCurrentDirectoryPath(rootPath)
        defer {
            fileManager.changeCurrentDirectoryPath(currentDirectoryPath)
        }

        return await SwiftPackageSources.files(inProjectAt: rootPath, testedBy: configuration, process: process)
    }

    /// Every path in the mutated project at `rootPath`, relative to it, but those in a hidden folder or hidden
    /// themselves, as a tool's `.swiftinfer` folder is, and those git ignores, as derived data often is. These are
    /// the project's paths that git lists, if it lists the project at `projectURL`: the listing comes from the project,
    /// not its copy, which a repository that ignores SwiftMutator's copies lists nothing in. Without git, none is
    /// left out for being ignored. A listed path that isn't on disk matches one that is whatever their case: on a disk
    /// that ignores it, as macOS's does, a file renamed only in case, without `git mv`, is listed by its old name. On a
    /// disk that doesn't, an ignored file whose path differs from a listed one's only in case is still left out.
    private func pathsNotHiddenOrIgnored(in rootPath: FilePath, listedIn projectURL: URL) async -> [FilePath] {
        let paths = (fileManager.subpaths(atPath: rootPath) ?? [])
            .filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
        guard let listed = await listProjectFiles(projectURL) else {
            return paths
        }

        let notIgnored = Set(listed)
        let onDisk = Set(paths)
        let renamedInCase = Set(listed.filter { !onDisk.contains($0) }.map { $0.lowercased() })
        return paths.filter { notIgnored.contains($0) || renamedInCase.contains($0.lowercased()) }
    }

    /// The Swift files to mutate among `candidatePaths`, and those coverage leaves out as a whole, whose mutants are
    /// counted as not covered.
    private func discoverSourceFiles(
        among candidatePaths: [FilePath],
        in state: AnyMutationTestState
    ) -> (files: [FilePath], uncovered: [FilePath]) {
        discoverSourceFiles(
            among: candidatePaths,
            inDirectoryAt: state.mutatedProjectDirectoryURL.path,
            excludingPathsIn: state.muterConfiguration.excludeFileList,
            ignoringFilesWithoutCoverage: state.projectCoverage.filesWithoutCoverage,
            keepingOnly: state.projectCoverage.filesInCoverage
        )
    }

    private func discoverSourceFiles(
        among candidatePaths: [FilePath],
        inDirectoryAt rootPath: FilePath,
        excludingPathsIn providedExcludeList: [FilePath],
        ignoringFilesWithoutCoverage filesWithoutCoverage: [FilePath],
        keepingOnly filesInCoverage: [FilePath]?
    ) -> (files: [FilePath], uncovered: [FilePath]) {
        let isExcluded = SourceFileExcludes.matcher(providedExcludeList)

        let swiftFiles = includeSwiftFiles(
            from: candidatePaths
                .exclude(isExcluded)
                .map { append(root: rootPath, to: $0) }
        )
        // Only Swift files are checked against coverage: each check resolves the path on disk, and a
        // project holds far more files than Swift sources.
        let isWithoutCoverage = anyOf(filesWithoutCoverage, root: rootPath)
        // The coverage names each of these, so none is left out below for being unknown to it.
        let uncovered = filesWithoutCoverage.isEmpty ? [] : swiftFiles.include(isWithoutCoverage)
        // A file the coverage data doesn't name has no code in any binary the tests ran, as an example app's or an
        // unused target's hasn't, so no test could kill its mutants. Without coverage, none is left out for this. The
        // exception is a file of globals' and static properties' values, which have no coverage regions, beside a file
        // the data names, so in what looks like a target the tests ran.
        let files = swiftFiles
            .exclude(isWithoutCoverage)
            .include(filesInCoverage.map { covered in
                let isCovered = anyOf(covered, root: rootPath)
                let root = rootPath.canonicalPath
                let folders = Set(covered.map { coveredFolder(of: $0, root: rootPath) }).subtracting([root])
                return { path in
                    isCovered(path) || (isBeside(folders, path, root: root) && CoverageRegions.holdsOnlyValues(path))
                }
            } ?? { _ in true })
        return (files, uncovered)
    }

    private func coveredFolder(of path: FilePath, root: FilePath) -> String {
        URL(fileURLWithPath: (path.hasPrefix("/") ? path : append(root: root, to: path)).canonicalPath)
            .deletingLastPathComponent().path
    }

    /// Whether the folder of the file at `path` is one of `folders`, holds one, or is in one, but for the project's
    /// own.
    private func isBeside(_ folders: Set<String>, _ path: FilePath, root: String) -> Bool {
        let folder = URL(fileURLWithPath: path.canonicalPath).deletingLastPathComponent().path
        return folder != root && folders.contains { covered in
            covered == folder || covered.hasPrefix(folder + "/") || folder.hasPrefix(covered + "/")
        }
    }

    /// Whether a path is one of `list`, the coverage's. Matches by canonical path, since the coverage tools may spell a
    /// file's path differently. A relative path, as SwiftPM's coverage gives one, is relative to the project at `root`.
    private func anyOf(
        _ list: [FilePath],
        root: FilePath
    ) -> (FilePath) -> Bool {
        let canonicalPaths = Set(list.map { ($0.hasPrefix("/") ? $0 : append(root: root, to: $0)).canonicalPath })
        return { path in canonicalPaths.contains(path.canonicalPath) }
    }

    /// The Swift files `--files-to-mutate` names, past the excludes and the coverage filter, as discovery leaves out
    /// any other file, those of them the coverage filter leaves out, and its entries that leave none. An entry is a
    /// file, a folder, which names every Swift file in it that isn't hidden or in a hidden folder, or a glob, as
    /// `exclude` takes one, whose matches are each a file or a folder. It is relative to the project, unless it is an
    /// absolute path in it. A file named twice, in letters of another case too, is mutated once.
    private func filesToMutate(
        in state: AnyMutationTestState
    ) -> ([FilePath], uncovered: [FilePath], [UnmatchedFilesToMutate]) {
        let root = state.mutatedProjectDirectoryURL.path
        let named = state.filesToMutate.map { entry in
            (entry, swiftFiles(namedBy: entry, in: state.projectDirectoryURL, copiedTo: root))
        }
        let inTheProject: (FilePath) -> FilePath? = { path in
            let relative = RepoRelativePath.of(path, under: state.mutatedProjectDirectoryURL)
            return relative.hasPrefix("/") ? nil : relative
        }
        var seen: Set<FilePath> = []
        let unique = named.flatMap(\.1).filter { seen.insert($0.canonicalPath).inserted }
        let (files, uncovered) = discoverSourceFiles(among: unique.compactMap(inTheProject).sorted(), in: state)

        let kept = Set(files.map(\.canonicalPath))
        let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
        let unmatched = named.filter { !$0.1.contains { kept.contains($0.canonicalPath) } }.map { entry, paths in
            let existing = paths.filter(fileManager.fileExists)
            let inProject = existing.compactMap(inTheProject)
            let reason: UnmatchedFilesToMutate.Reason = if existing.isEmpty {
                .noSwiftFile
            } else if inProject.isEmpty {
                .outsideTheProject
            } else if inProject.allSatisfy(SourceFileExcludes.isAlwaysExcluded) {
                .neverMutated
            } else if inProject.allSatisfy(isExcluded) {
                .excluded
            } else {
                .withoutCoverage
            }
            return UnmatchedFilesToMutate(entry: entry, reason: reason)
        }
        return (files, uncovered, unmatched)
    }

    /// The paths in the copy at `root` of the Swift files `entry` names, whether or not they exist. An absolute path
    /// in the project at `project` names its copy; any other path is relative to the project, `/` or not.
    private func swiftFiles(namedBy entry: String, in project: URL, copiedTo root: FilePath) -> [FilePath] {
        var entry = entry
        if entry.hasPrefix("/"), let relative = [project.path, project.path.canonicalPath].lazy
            .map({ RepoRelativePath.of(entry, under: URL(fileURLWithPath: $0)) })
            .first(where: { !$0.hasPrefix("/") }) {
            entry = relative
        }
        let paths = entry.contains("*")
            ? matches(ofGlob: entry, inDirectoryAt: root)
            : [append(root: root, to: entry)]
        return paths.map(standardizing(path:)).flatMap { path in
            fileManager.isDirectory(atPath: path) ? swiftFiles(inFolderAt: path) : [path]
        }
        .filter(swiftFiles(path:))
    }

    /// The files and folders in the project at `root` that `glob` matches, as an `exclude` glob would, but those that
    /// are hidden or in a hidden folder.
    private func matches(ofGlob glob: String, inDirectoryAt root: FilePath) -> [FilePath] {
        let pattern = ExcludeGlob(glob)
        return (fileManager.subpaths(atPath: root) ?? [])
            .filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .filter(pattern.matches)
            .sorted()
            .map { append(root: root, to: $0) }
    }

    private func swiftFiles(inFolderAt folder: FilePath) -> [FilePath] {
        (fileManager.subpaths(atPath: folder) ?? [])
            .filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
            .filter(swiftFiles(path:))
            .map { append(root: folder, to: $0) }
    }

    private func append(
        root: FilePath,
        to path: FilePath
    ) -> FilePath {
        Path(root + "/" + path).normal.description
    }

    private func standardizing(
        path: String
    ) -> String {
        let components = (path as NSString).pathComponents
        guard components.contains(".") || components.contains("..") else {
            return path
        }
        let result = URL(
            string: path,
            relativeTo: URL(
                fileURLWithPath: fileManager.currentDirectoryPath
            )
        )
        .map(\.absoluteString)
        .map(dropScheme)
        ?? path

        return result
    }

    private func includeSwiftFiles(
        from paths: [FilePath]
    ) -> [FilePath] {
        paths
            .include(swiftFiles)
            .include(fileManager.fileExists)
            .sorted()
    }

    private func swiftFiles(path: FilePath) -> Bool {
        path.hasSuffix(".swift")
    }

    private func dropScheme(
        from path: FilePath
    ) -> FilePath {
        URLComponents(string: path)
            .map(\.scheme)
            .flatMap { $0 }
            .map { path.removingSubrange(path.range(of: "\($0)://")) }
            ?? path
    }
}
