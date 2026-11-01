import Foundation
import Pathos

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
        let sourceFileCandidates = state.filesToMutate.isEmpty
            ? discoverSourceFiles(
                among: (listed ?? []).filter(isChosen(by: state)),
                inDirectoryAt: state.mutatedProjectDirectoryURL.path,
                excludingPathsIn: state.muterConfiguration.excludeFileList,
                ignoringFilesWithoutCoverage: state.projectCoverage.filesWithoutCoverage,
                keepingOnly: state.projectCoverage.filesInCoverage
            )
            : findFilesToMutate(
                files: state.filesToMutate,
                inDirectoryAt: state.mutatedProjectDirectoryURL.path
            )

        let failure: MuterError = state.filesToMutate.isEmpty
            ? .noSourceFilesDiscovered
            : .noSourceFilesOnExclusiveList

        events.send(.sourceFileDiscoveryFinished(sourceFileCandidates))

        if let selection = state.changeSelection {
            try check(sourceFileCandidates, against: selection, in: state)
        }
        if !sourceFileCandidates.isEmpty {
            return [.sourceFileCandidatesDiscovered(sourceFileCandidates)]
        } else {
            throw failure
        }
    }
}

private extension DiscoverSourceFiles {
    /// With `--since`, whether a path in the project is one of the files it chose; without, every path is.
    func isChosen(by state: AnyMutationTestState) -> (FilePath) -> Bool {
        guard let selection = state.changeSelection else { return { _ in true } }
        let chosen = Set(selection.files.map(\.path))
        return { chosen.contains($0.precomposedStringWithCanonicalMapping) }
    }

    /// That `--since` left a file to mutate, and that each is as git compared it: the copy is made after, and the lines
    /// of a file changed in between would be wrong.
    func check(_ candidates: [FilePath], against selection: ChangeSelection, in state: AnyMutationTestState) throws {
        guard !candidates.isEmpty else {
            let isExcluded = SourceFileExcludes.matcher(state.muterConfiguration.excludeFileList)
            let count = selection.files.filter { !isExcluded($0.path) }.count
            throw NothingToMutate(reason: .noFileDiscovered(count: count), selection: selection)
        }
        for candidate in candidates {
            let path = RepoRelativePath.of(candidate, under: state.mutatedProjectDirectoryURL)
                .precomposedStringWithCanonicalMapping
            guard let file = selection.file(at: path) else { continue }
            if let copied = state.projectTree?.files[path], copied != file.sha256 {
                throw ChangeSelectionError.changedDuringTheRun(path: path)
            }
        }
    }
}

private extension DiscoverSourceFiles {
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

    private func discoverSourceFiles(
        among candidatePaths: [FilePath],
        inDirectoryAt rootPath: FilePath,
        excludingPathsIn providedExcludeList: [FilePath],
        ignoringFilesWithoutCoverage filesWithoutCoverage: [FilePath],
        keepingOnly filesInCoverage: [FilePath]?
    ) -> [FilePath] {
        let isExcluded = SourceFileExcludes.matcher(providedExcludeList)

        return includeSwiftFiles(
            from: candidatePaths
                .exclude(isExcluded)
                .map { append(root: rootPath, to: $0) }
        )
        // Only Swift files are checked against coverage: each check resolves the path on disk, and a
        // project holds far more files than Swift sources.
        .exclude(anyOf(filesWithoutCoverage, root: rootPath))
        // A file the coverage data doesn't name has no code in any binary the tests ran, as an example app's or an
        // unused target's hasn't, so no test could kill its mutants. Without coverage, none is left out for this.
        .include(filesInCoverage.map { anyOf($0, root: rootPath) } ?? { _ in true })
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

    private func findFilesToMutate(
        files: [FilePath],
        inDirectoryAt path: FilePath
    ) -> [FilePath] {
        let glob = files
            .map { expandGlobExpressions(root: path, pattern: $0) }
            .flatMap { $0 }
        let list = files.map { append(root: path, to: $0) }
        let result = (glob + list).map(standardizing(path:))
        return includeSwiftFiles(from: result)
    }

    private func expandGlobExpressions(
        root: FilePath,
        pattern: FilePath
    ) -> [FilePath] {
        let path = Path(append(root: root, to: pattern))
        guard pattern.contains("*"), let paths = try? path.glob(),
              !paths.isEmpty
        else {
            return []
        }

        return paths.map(\.description)
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
