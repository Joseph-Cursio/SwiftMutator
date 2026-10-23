import Foundation

/// The project's own source files among those a coverage report names, by their path in the project, as both build
/// systems read them. Only these count toward the project's coverage: the reports also name test files, the packages
/// the project depends on and files the build generates, by absolute path.
struct ProjectSourceFiles {
    /// The project's folder as given and with its links resolved, each ending in `/`.
    private let roots: [String]
    /// The build's own folders in the project, relative to it, each ending in `/`.
    private let buildFolders: [String]
    /// The files test targets build, relative to the project.
    private let testFiles: Set<FilePath>

    /// `buildFolders` are folders the build used, such as the derived data an xcodebuild run was given in the project,
    /// which holds the packages the project depends on and the files the build generates. `testFiles` are files that
    /// test targets build, as a report names them, which the rules for paths miss when a test target isn't in a
    /// `Tests` folder.
    init(root: FilePath, buildFolders: [FilePath] = [], testFiles: [FilePath] = []) {
        let roots = Set([root, root.canonicalPath]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        self.roots = roots
        self.buildFolders = buildFolders
            .compactMap { Self.relativePath($0, to: roots) ?? Self.relativePath($0.canonicalPath, to: roots) }
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        self.testFiles = Set(testFiles.compactMap {
            Self.relativePath($0, to: roots) ?? Self.relativePath($0.canonicalPath, to: roots)
        })
    }

    /// `path` relative to the project, or nil if it isn't one of the project's own source files. A tool can name a
    /// file through a link the project's path doesn't take, as xcodebuild names one in `/private/tmp` by `/tmp`, so a
    /// path outside the project is checked again with its links resolved.
    func pathInProject(_ path: FilePath) -> FilePath? {
        guard let inProject = Self.relativePath(path, to: roots) ?? Self.relativePath(path.canonicalPath, to: roots),
              !buildFolders.contains(where: inProject.hasPrefix)
        else {
            return nil
        }

        return Self.isTestOrBuildFile(inProject) || testFiles.contains(inProject) ? nil : inProject
    }

    /// Whether a file with `lines` lines to run, of which the tests ran `covered`, has no coverage: its share of them,
    /// a percentage from 0 to 100, is at or below `threshold`. Worked out from the counts, so a file exactly at the
    /// threshold is: llvm-cov's and xccov's own shares can come out just above it, as 7 of 100 lines does.
    static func hasNoCoverage(covered: Int, of lines: Int, threshold: Double) -> Bool {
        // A file with no lines to run has nothing to mutate, and saying it has no coverage would be wrong.
        lines > 0 && Double(covered) * 100 / Double(lines) <= threshold
    }

    private static func relativePath(_ path: FilePath, to roots: [String]) -> FilePath? {
        roots.first(where: path.hasPrefix).map { String(path.dropFirst($0.count)) }
    }

    /// A file in a `.build` folder, such as that of a package in a subfolder, or a test file, as discovery tells them:
    /// one in a `Tests` folder, or whose name ends in `Tests.swift`. `path` is relative to the project.
    private static func isTestOrBuildFile(_ path: String) -> Bool {
        let folders = path.split(separator: "/").dropLast()
        return folders.contains(".build") || folders.contains("Tests") || path.hasSuffix("Tests.swift")
    }
}
