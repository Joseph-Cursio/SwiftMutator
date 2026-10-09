import Foundation
import Pathos

struct DiscoverSourceFiles: MutationStep {
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        notificationCenter.post(
            name: .sourceFileDiscoveryStarted,
            object: nil
        )

        let sourceFileCandidates = state.filesToMutate.isEmpty
            ? discoverSourceFiles(
                inDirectoryAt: state.mutatedProjectDirectoryURL.path,
                excludingPathsIn: state.muterConfiguration.excludeFileList,
                ignoringFilesWithoutCoverage: state.projectCoverage.filesWithoutCoverage
            )
            : findFilesToMutate(
                files: state.filesToMutate,
                inDirectoryAt: state.mutatedProjectDirectoryURL.path
            )

        let failure: MuterError = state.filesToMutate.isEmpty
            ? .noSourceFilesDiscovered
            : .noSourceFilesOnExclusiveList

        notificationCenter.post(
            name: .sourceFileDiscoveryFinished,
            object: sourceFileCandidates
        )

        if !sourceFileCandidates.isEmpty {
            return [.sourceFileCandidatesDiscovered(sourceFileCandidates)]
        } else {
            throw failure
        }
    }
}

private extension DiscoverSourceFiles {
    /// Package manifests, versioned (`Package@swift-6.0.swift`) or not, are never mutated: every `swift test`
    /// run in a worker folder has one environment, so SwiftPM reuses the baseline's cached manifest and a
    /// mutant in one would never switch on.
    private var defaultExcludeList: [FilePath] {
        [
            "/.swiftpm/",
            "/.build/",
            "/Build/",
            "/Carthage/",
            "/muter_tmp/",
            "/Pods/",
            "/Spec/",
            "/Tests/",
            "Tests.swift",
            "/fastlane/",
            "/Package.swift",
            "/Package@swift-",
        ]
    }

    private func discoverSourceFiles(
        inDirectoryAt rootPath: FilePath,
        excludingPathsIn providedExcludeList: [FilePath],
        ignoringFilesWithoutCoverage filesWithoutCoverage: [FilePath]
    ) -> [FilePath] {
        let excludeList = providedExcludeList + defaultExcludeList
        let subpaths = (fileManager.subpaths(atPath: rootPath) ?? [])
            .map { "./" + $0 }

        return includeSwiftFiles(
            from: subpaths
                .exclude(
                    pathsContainingItems(
                        from: excludeList,
                        root: rootPath
                    )
                )
                .map { String($0.dropFirst(2)) }
                .map { append(root: rootPath, to: $0) }
        )
        // Only Swift files are checked against coverage: each check resolves the path on disk, and a
        // project holds far more files than Swift sources.
        .exclude(filesWithoutCoverageList(filesWithoutCoverage, root: rootPath))
    }

    private func pathsContainingItems(
        from excludeList: [FilePath],
        root: FilePath
    ) -> (FilePath) -> Bool {
        let excludeAlso: [FilePath] = excludeList.flatMap { path in
            path.contains("*")
                ? expandGlobExpressions(root: root, pattern: path)
                : [path]
        }

        return { path in
            for item in excludeAlso where path.contains(item) {
                return true
            }
            return false
        }
    }

    /// Matches by canonical path, since the coverage tools may spell a file's path differently. A relative path, as
    /// SwiftPM's coverage gives one, is relative to the project at `root`.
    private func filesWithoutCoverageList(
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
