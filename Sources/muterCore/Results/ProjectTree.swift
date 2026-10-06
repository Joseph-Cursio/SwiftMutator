import Foundation

/// A project's files as a session tested them: each one's SHA-256 by its path relative to the project.
struct ProjectTree: Codable, Equatable {
    /// How the files were found: by git, or, outside a repository, by a walk of every file.
    enum Listing: String, Codable {
        case git
        case walk
    }

    struct FileChange: Equatable {
        enum Kind: String {
            case changed
            case added
            case removed
        }

        let path: String
        let kind: Kind
    }

    let listedBy: Listing
    /// A symbolic link's entry is "link:" + the SHA-256 of the path it points to; it is never followed. The files of a
    /// local package outside the project are under its path from the project, which starts with `../`.
    let files: [String: String]
    /// Paths inside the project that are left out: the `-o` report and its `.partial` sibling, which the run itself
    /// writes, and the configuration file, whose settings the header records (`excludedPaths`).
    let excluded: [String]
    /// SHA-256 over every "path\0hash\n", sorted by path.
    let treeSHA256: String
}

extension ProjectTree {
    /// Folders no outcome is read from, at any depth: build products, git's own, and Xcode's per-user state.
    static let prunedComponents: Set = [".build", ".git", ".swiftpm", "DerivedData", "xcuserdata"]
    static let prunedNames: Set = [".DS_Store"]
    /// What SwiftMutator itself writes at the root of the project it copies.
    static let prunedAtRoot: Set = ["muter-mappings.json", ".swiftmutator-active-mutant", "muter.xctestrun"]

    /// Lists the project at `listingRoot` (git; without it, a walk of `hashingRoot`), adds every Swift and package
    /// file under `hashingRoot`, and hashes each as `hashingRoot` holds it. A listed path that isn't there is left out,
    /// so a tracked file deleted from the working tree reads as removed. The local packages outside the project that
    /// its manifests name (`LocalPackageDependencies`) are listed and hashed the same way where they are, by their
    /// paths relative to the project, which start with `../`: no copy is made of them, and every session builds them.
    ///
    /// The listing comes from the project, not its copy: a repository that ignores SwiftMutator's copies, or that
    /// holds the project in a folder of its own, lists nothing, or the wrong files, in the copy.
    static func fingerprint(
        listingIn listingRoot: URL,
        hashingIn hashingRoot: URL,
        excluding excluded: [String],
        list: ProjectFileListing
    ) -> ProjectTree {
        let listed = list(listingRoot)
        let paths = self.paths(listed: listed, under: hashingRoot).subtracting(excluded)
        var files: [String: String] = [:]
        for path in paths {
            files[path] = digest(of: hashingRoot.appendingPathComponent(path))
        }
        for dependency in LocalPackageDependencies.outside(listingRoot, manifests: paths) {
            for path in self.paths(listed: list(dependency.url), under: dependency.url) {
                files[dependency.relativePath + "/" + path] = digest(of: dependency.url.appendingPathComponent(path))
            }
        }
        return ProjectTree(
            listedBy: listed == nil ? .walk : .git,
            files: files,
            excluded: Set(excluded).sorted(),
            treeSHA256: treeHash(of: files)
        )
    }

    /// The files under `root` that `listed` names, unless pruned, and every Swift and package file under it; without a
    /// listing, every file under it.
    static func paths(listed: [String]?, under root: URL) -> Set<String> {
        guard let listed else {
            return Set(walk(root, keeping: { _ in true }, skippingCheckouts: false))
        }
        return Set(listed.filter { !isPruned($0) })
            .union(walk(root, keeping: isAlwaysIncluded, skippingCheckouts: true))
    }

    /// `*.swift` (which includes Package.swift and Package@swift-*.swift) and `.swift-version` at any depth.
    /// `Package.resolved` only at the root and in `*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` or
    /// `*.xcworkspace/xcshareddata/swiftpm/`: a nested package's can't change the root build.
    static func isAlwaysIncluded(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last else { return false }
        if name.hasSuffix(".swift") || name == ".swift-version" {
            return true
        }
        guard name == "Package.resolved" else { return false }
        if components.count == 1 {
            return true
        }
        // An Xcode project's own workspace is `project.xcworkspace` inside it, so this covers both.
        return components.count >= 4
            && components[components.count - 4].hasSuffix(".xcworkspace")
            && components[components.count - 3] == "xcshareddata"
            && components[components.count - 2] == "swiftpm"
    }

    /// Whether `path` lies in a pruned folder, or is a pruned file.
    static func isPruned(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { return true }
        return components.contains(where: prunedComponents.contains)
            || prunedNames.contains(name)
            || components.count == 1 && prunedAtRoot.contains(name)
    }

    /// `FileManager.enumerator` (it never follows a symbolic link to a folder). It skips the descendants of pruned
    /// folders, and in git mode of any folder holding a `.git` entry (worktrees and ignored clones: git lists the
    /// nested checkouts it knows about itself). It calls `skipDescendants()` only on folders.
    static func walk(_ root: URL, keeping: (String) -> Bool, skippingCheckouts: Bool) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var paths: [String] = []
        while let path = enumerator.nextObject() as? String {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                let name = (path as NSString).lastPathComponent
                if prunedComponents.contains(name)
                    || skippingCheckouts && exists(root.appendingPathComponent(path).appendingPathComponent(".git")) {
                    // On Darwin, skipping the descendants of anything but a folder skips the next folder.
                    enumerator.skipDescendants()
                }
            } else if !isPruned(path), keeping(path) {
                paths.append(path)
            }
        }
        return paths
    }

    /// What changed from `recorded`, after leaving out both sessions' excluded paths.
    func changes(since recorded: ProjectTree) -> [FileChange] {
        let paths = Set(files.keys).union(recorded.files.keys).subtracting(excluded).subtracting(recorded.excluded)
        return paths.sorted().compactMap { path in
            switch (recorded.files[path], files[path]) {
            case let (was?, isNow?):
                return was == isNow ? nil : FileChange(path: path, kind: .changed)
            case (nil, _?):
                return FileChange(path: path, kind: .added)
            case (_?, nil):
                return FileChange(path: path, kind: .removed)
            case (nil, nil):
                return nil
            }
        }
    }

    /// What a run with `options` leaves out of its project's tree, relative to `projectRoot`, if it lies inside it: the
    /// `-o` report and its partial sibling, which the run itself writes, and the configuration file it loads, whose
    /// settings the header records. A resume compares those key by key, so a change that no result depends on, such
    /// as `mutationTestWorkers`, is only said.
    static func excludedPaths(_ options: Run.Options, under projectRoot: URL) -> [String] {
        reportPaths(options, under: projectRoot)
            + relativePaths([LoadConfiguration.configurationPath(options, in: projectRoot.path)], under: projectRoot)
    }

    /// The `-o` report and its partial sibling, relative to `projectRoot`, if they lie inside it.
    static func reportPaths(_ options: Run.Options, under projectRoot: URL) -> [String] {
        let requested = options.reportOptions.path
        return relativePaths([requested, PartialReport.path(besides: requested)], under: projectRoot)
    }

    /// Each of `paths` relative to `projectRoot`, if it lies inside it.
    static func relativePaths(_ paths: [String?], under projectRoot: URL) -> [String] {
        let root = URL(fileURLWithPath: resolved(projectRoot.path))
        return paths.compactMap { path in
            guard let path, !path.isEmpty else { return nil }
            let relative = RepoRelativePath.of(resolved(path), under: root)
            return relative.hasPrefix("/") ? nil : relative
        }
    }

    /// SHA-256 over every "path\0hash\n", sorted by the paths' bytes; empty without CryptoKit.
    static func treeHash(of files: [String: String]) -> String {
        let lines = files.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { "\($0)\0\(files[$0] ?? "")\n" }
            .joined()
        return FileDigest.sha256(of: Data(lines.utf8)) ?? ""
    }
}

private extension ProjectTree {
    /// A file's SHA-256, or a symbolic link's "link:" + the SHA-256 of where it points; nil for anything else, and
    /// for something that isn't there.
    static func digest(of url: URL) -> String? {
        switch (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType {
        case .typeRegular?:
            return FileDigest.sha256(of: url)
        case .typeSymbolicLink?:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                .flatMap { FileDigest.sha256(of: Data($0.utf8)) }
                .map { "link:" + $0 }
        default:
            return nil
        }
    }

    /// Whether anything is at `url`, a symbolic link that points nowhere included.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// `path`, absolute, with every symbolic link resolved in the part of it that exists: a report not written yet,
    /// in a folder not made yet, still compares with the project's path, which `getcwd()` gives resolved.
    static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !exists(existing) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.path.canonicalPath) { ($0 as NSString).appendingPathComponent($1) }
    }
}

extension [ProjectTree.FileChange] {
    /// Split by whether a glob matches the path: fnmatch with no flags, so `*` crosses `/`; a leading "./" is dropped.
    func partition(by globs: [String]) -> (waived: [ProjectTree.FileChange], unwaived: [ProjectTree.FileChange]) {
        let patterns = globs.map { glob in
            var pattern = Substring(glob)
            while pattern.hasPrefix("./") {
                pattern = pattern.dropFirst(2)
            }
            return String(pattern)
        }
        var waived: [ProjectTree.FileChange] = []
        var unwaived: [ProjectTree.FileChange] = []
        for change in self {
            if patterns.contains(where: { fnmatch($0, change.path, 0) == 0 }) {
                waived.append(change)
            } else {
                unwaived.append(change)
            }
        }
        return (waived, unwaived)
    }
}

/// A project's files as git sees them: tracked, and untracked but not ignored, by the project's own ignore files and
/// the user's global ones.
enum GitFileListing {
    /// How many repositories deep nested ones are listed by their own git; deeper ones are walked.
    private static let maximumDepth = 4

    /// `git ls-files` on `directory`, or nil if git fails (no repository, git missing, killed), or if `directory` is in
    /// a folder its repository ignores. A folder entry (a submodule, or an untracked nested repository listed as
    /// `dir/`) is replaced by its own listing, prefixed; failing that, by a walk. Depth 4 at most.
    static func list(in directory: URL) -> [String]? {
        guard !isIgnoredByItsRepository(directory) else { return nil }
        return list(in: directory, depth: 0)
    }

    /// The environment git runs in: `environment` without the variables that name a repository, as a hook's does,
    /// so `-C` alone says which one; and without optional locks, so a listing never refreshes the user's index.
    static func environment(_ environment: [String: String]) -> [String: String] {
        var environment = environment.filter { !repositoryVariables.contains($0.key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }

    /// What `git rev-parse --local-env-vars` names.
    private static let repositoryVariables: Set = [
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
        "GIT_OBJECT_DIRECTORY", "GIT_DIR", "GIT_WORK_TREE", "GIT_IMPLICIT_WORK_TREE", "GIT_GRAFT_FILE",
        "GIT_INDEX_FILE", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
        "GIT_COMMON_DIR",
    ]

    /// Whether `directory` lies below its repository's top level, in a folder the repository ignores. git lists none of
    /// the untracked files there, and a listing of only the files forced in would leave out every test fixture.
    private static func isIgnoredByItsRepository(_ directory: URL) -> Bool {
        // At the top level `.` reads as ignored when the repository ignores everything, though git lists what it
        // tracks.
        guard let prefix = run(["rev-parse", "--show-prefix"], in: directory), prefix.status == 0,
              !String(decoding: prefix.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        // Without --no-index, a folder that holds a file forced in doesn't read as ignored.
        return run(["check-ignore", "-q", "--no-index", "."], in: directory)?.status == 0
    }

    private static func list(in directory: URL, depth: Int) -> [String]? {
        guard let entries = listing(in: directory) else { return nil }
        var files: [String] = []
        for entry in entries {
            let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let folder = directory.appendingPathComponent(path)
            guard entry.hasSuffix("/") || isFolder(folder) else {
                files.append(entry)
                continue
            }
            let listing = depth < maximumDepth ? list(in: folder, depth: depth + 1) : nil
            let inside = listing ?? ProjectTree.walk(folder, keeping: { _ in true }, skippingCheckouts: false)
            files += inside.map { path + "/" + $0 }
        }
        return files
    }

    private static func listing(in directory: URL) -> [String]? {
        guard let git = run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: directory),
              git.status == 0
        else { return nil }
        let entries = Set(git.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        // The folder is a submodule that isn't checked out: its files aren't git's to list, so it is walked.
        guard !entries.contains("./"), !entries.contains(".") else { return nil }
        return entries.sorted()
    }

    /// git with `arguments`, in `directory`: its exit status and output, or nil if it didn't run or was killed.
    private static func run(_ arguments: [String], in directory: URL) -> (status: Int32, output: Data)? {
        let git = Foundation.Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory.path] + arguments
        git.environment = environment(ProcessInfo.processInfo.environment)
        let output = Pipe()
        git.standardOutput = output
        git.standardError = FileHandle.nullDevice
        do { try git.run() } catch { return nil } // terminationStatus of a process that never ran raises
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data() // before waiting: a listing overfills a pipe
        git.waitUntilExit()
        guard git.terminationReason == .exit else { return nil }
        return (git.terminationStatus, data)
    }

    /// A folder, not a symbolic link to one: git lists a link as a file of its own.
    private static func isFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
