import Foundation
import Pathos

extension DiscoverSourceFiles {
    /// `SwiftPackageSources.files`, run in the mutated project at `rootPath`, as the coverage run and the tests are:
    /// a relative `executable` or `--package-path` is relative to it.
    func packageSourceFiles(
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
    func pathsNotHiddenOrIgnored(in rootPath: FilePath, listedIn projectURL: URL) async -> [FilePath] {
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
    func discoverSourceFiles(
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
    func filesToMutate(
        in state: AnyMutationTestState
    ) -> NamedFiles {
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
        return NamedFiles(files: files, uncovered: uncovered, unmatched: unmatched)
    }

    /// The paths in the copy at `root` of the Swift files `entry` names, whether or not they exist. An absolute path
    /// in the project at `project` names its copy; any other path is relative to the project, `/` or not.
    private func swiftFiles(namedBy entry: String, in project: URL, copiedTo root: FilePath) -> [FilePath] {
        var entry = entry
        if entry.hasPrefix("/"), let relative = [project.path, project.path.canonicalPath]
            .lazy
            .map({ RepoRelativePath.of(entry, under: URL(fileURLWithPath: $0)) })
            .first(where: { !$0.hasPrefix("/") }) {
            entry = relative
        }
        let paths = entry.contains("*")
            ? matches(ofGlob: entry, inDirectoryAt: root)
            : [append(root: root, to: entry)]
        return paths
            .map(standardizing(path:))
            .flatMap { path in
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
        let components = path.pathComponents
        guard components.contains(".") || components.contains("..") else {
            return path
        }
        return URL(
            string: path,
            relativeTo: URL(
                fileURLWithPath: fileManager.currentDirectoryPath
            )
        )
        .map(\.absoluteString)
        .map(dropScheme)
        ?? path
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
            .flatMap(\.self)
            .map { path.removingSubrange(path.range(of: "\($0)://")) }
            ?? path
    }
}
