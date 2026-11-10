import Foundation

/// A project's files as a session tested them: each one's SHA-256 by its path relative to the project.
struct ProjectTree: Codable, Equatable {
    /// How the files were found: by git, or, outside a repository, by a walk of every file.
    enum Listing: String, Codable {
        case git
        case walk
    }

    /// How a file differs from the tree it is compared with (`FileChange`).
    enum FileChangeKind: String {
        case changed
        case added
        case removed
    }

    struct FileChange: Equatable {
        let path: String
        let kind: FileChangeKind
    }

    let listedBy: Listing
    /// A symbolic link's entry is `linkPrefix` + the SHA-256 of the path it points to; it is never followed. The files
    /// of a local package outside the project are under its path from the project, which starts with `../`.
    let files: [String: String]
    /// Paths inside the project that are left out: the `-o` report, each other report the run saves, and their
    /// `.partial` siblings, which the run itself writes, and the configuration file, whose settings the header records
    /// (`excludedPaths`).
    let excluded: [String]
    /// SHA-256 over every "path\0hash\n", sorted by path.
    let treeSHA256: String

    /// What a symbolic link's entry in `files` starts with.
    static let linkPrefix = "link:"
    /// Folders no outcome is read from, at any depth: build products, git's own, and Xcode's per-user state.
    static let prunedComponents: Set = [".build", ".git", ".swiftpm", "DerivedData", "xcuserdata"]
    static let prunedNames: Set = [".DS_Store"]
    /// What SwiftMutator itself writes at the root of the project it copies, with each xcodebuild worker's
    /// `muter-worker<n>.xctestrun` (`MutationTestingDelegate.isWorkerTestRunFileName`). Earlier versions wrote the
    /// active-mutant file there too, as `.swiftmutator-active-mutant`; it is still left out, so a fingerprint doesn't
    /// change.
    /// `muter.triage.yml` isn't written by a run, but no result reads it: labelling a mutant must refuse no `--resume`,
    /// and test nothing again in a `--reuse`. Nor does any result read `muter.baseline.yml`, which `--write-baseline`
    /// writes: committing a new one must refuse neither either. A baseline file elsewhere is a project file.
    static let prunedAtRoot: Set = [
        "muter-mappings.json", ".swiftmutator-active-mutant", "muter.xctestrun", TriageFile.fileName,
        BaselineFile.fileName,
    ]

    /// Lists the project at `listingRoot` (git; without it, a walk of `hashingRoot`), adds every Swift and package
    /// file under `hashingRoot`, and hashes each as `hashingRoot` holds it. A listed path that isn't there is left out,
    /// so a tracked file deleted from the working tree reads as removed. The local packages outside the project that
    /// its manifests name (`LocalPackageDependencies`) are listed and hashed the same way where they are, by their
    /// paths relative to the project, which start with `../`: no copy is made of them, and every session builds them.
    ///
    /// The listing comes from the project, not its copy: a repository that ignores SwiftMutator's copies, or that
    /// holds the project in a folder of its own, lists nothing, or the wrong files, in the copy.
    ///
    /// Nothing in `prunedFolders`, folders by their paths relative to `hashingRoot`, is listed or hashed, whatever it
    /// holds.
    static func fingerprint(
        listingIn listingRoot: URL,
        hashingIn hashingRoot: URL,
        excluding excluded: [String],
        list: ProjectFileListing,
        pruning prunedFolders: Set<String> = []
    ) async -> Self {
        await fingerprinting(
            listingIn: listingRoot,
            hashingIn: hashingRoot,
            excluding: excluded,
            list: list,
            pruning: prunedFolders
        ).tree
    }

    /// What `fingerprint` found on its way to the tree, so that a run can tell what it builds from outside the project
    /// (`OutsideProjectCode`) without listing the project again.
    struct Fingerprinting {
        let tree: ProjectTree
        /// The paths it listed in the project, relative to it, less those left out.
        let paths: Set<String>
        /// The local packages outside the project whose files the tree holds.
        let localPackages: [LocalPackageDependencies.Dependency]
    }

    /// `fingerprint`, with the paths it listed and the local packages it found.
    static func fingerprinting(
        listingIn listingRoot: URL,
        hashingIn hashingRoot: URL,
        excluding excluded: [String],
        list: ProjectFileListing,
        pruning prunedFolders: Set<String> = []
    ) async -> Fingerprinting {
        let listed = await list(listingRoot)
        let paths = self.paths(listed: listed, under: hashingRoot, pruning: prunedFolders).subtracting(excluded)
        var hashes: [String: String] = [:]
        for path in paths {
            hashes[path] = digest(of: hashingRoot.appendingPathComponent(path))
        }
        let localPackages = LocalPackageDependencies.outside(listingRoot, manifests: paths)
        for dependency in localPackages {
            for path in self.paths(listed: await list(dependency.url), under: dependency.url) {
                hashes[dependency.relativePath + "/" + path] = digest(of: dependency.url.appendingPathComponent(path))
            }
        }
        let tree = Self(
            listedBy: listed == nil ? .walk : .git,
            files: hashes,
            excluded: Set(excluded).sorted(),
            treeSHA256: treeHash(of: hashes)
        )
        return Fingerprinting(tree: tree, paths: paths, localPackages: localPackages)
    }

    /// The files under `root` that `listed` names, unless pruned, and every Swift and package file under it; without a
    /// listing, every file under it. None is in `prunedFolders`, folders by their paths relative to `root`.
    static func paths(listed: [String]?, under root: URL, pruning prunedFolders: Set<String> = []) -> Set<String> {
        guard let listed else {
            return Set(walk(root, keeping: { _ in true }, skippingCheckouts: false, pruning: prunedFolders))
        }
        return Set(listed.filter { !isPruned($0) && !isInside($0, prunedFolders) })
            .union(walk(root, keeping: isAlwaysIncluded, skippingCheckouts: true, pruning: prunedFolders))
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
            || components.count == 1
            && (prunedAtRoot.contains(name) || MutationTestingDelegate.isWorkerTestRunFileName(name))
    }

    /// `FileManager.enumerator` (it never follows a symbolic link to a folder). It skips the descendants of pruned
    /// folders, of `prunedFolders`, by their paths relative to `root`, and in git mode of any folder holding a `.git`
    /// entry (worktrees and ignored clones: git lists the nested checkouts it knows about itself). It calls
    /// `skipDescendants()` only on folders.
    static func walk(
        _ root: URL,
        keeping: (String) -> Bool,
        skippingCheckouts: Bool,
        pruning prunedFolders: Set<String> = []
    ) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var paths: [String] = []
        while let path = enumerator.nextObject() as? String {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                let name = path.lastPathComponent
                if prunedComponents.contains(name) || prunedFolders.contains(path)
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

    /// Whether `path` is in one of `folders`, at any depth.
    static func isInside(_ path: String, _ folders: Set<String>) -> Bool {
        folders.contains { path.hasPrefix($0 + "/") }
    }

    /// What changed from `recorded`, after leaving out both sessions' excluded paths.
    func changes(since recorded: Self) -> [FileChange] {
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
    /// `-o` report, the other `reports` it saves (`MuterConfiguration.reportRequests(in:)`), and their partial
    /// siblings, which the run itself writes, and the configuration file it loads, whose settings the header records. A
    /// resume compares those key by key, so a change that no result depends on, such as `mutationTestWorkers`, is
    /// only said.
    static func excludedPaths(
        _ options: Run.Options,
        under projectRoot: URL,
        reports: [ReportRequest] = []
    ) -> [String] {
        reportPaths(options, under: projectRoot, reports: reports)
            + relativePaths([LoadConfiguration.configurationPath(options, in: projectRoot.path)], under: projectRoot)
    }

    /// What the run of `state` leaves out of its project's tree, as `excludedPaths(_:under:reports:)` gives it, with
    /// the reports its configuration saves.
    static func excludedPaths(of state: AnyMutationTestState, under projectRoot: URL) -> [String] {
        excludedPaths(
            state.runOptions,
            under: projectRoot,
            reports: state.muterConfiguration.reportRequests(in: state.projectDirectoryURL)
        )
    }

    /// The `-o` report, the other `reports`, and the partial sibling of each, relative to `projectRoot`, if they lie
    /// inside it.
    static func reportPaths(
        _ options: Run.Options,
        under projectRoot: URL,
        reports: [ReportRequest] = []
    ) -> [String] {
        let requested = [options.reportOptions.path] + reports.map(\.path)
        return relativePaths(requested.flatMap { [$0, PartialReport.path(besides: $0)] }, under: projectRoot)
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

    /// SHA-256 over every "path\0hash\n", sorted by the paths' bytes.
    static func treeHash(of files: [String: String]) -> String {
        let lines = files.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { "\($0)\0\(files[$0] ?? "")\n" }
            .joined()
        return FileDigest.sha256(of: Data(lines.utf8))
    }

    /// The tree `delta` makes of this one, or nil if `delta` wasn't recorded against it, or doesn't make the tree it
    /// recorded.
    func applying(_ delta: ProjectTreeDelta) -> Self? {
        guard delta.baseTreeSHA256 == treeSHA256 else { return nil }
        var merged = files.merging(delta.files) { _, recorded in recorded }
        for path in delta.removed {
            merged.removeValue(forKey: path)
        }
        let tree = Self(
            listedBy: delta.listedBy,
            files: merged,
            excluded: delta.excluded,
            treeSHA256: Self.treeHash(of: merged)
        )
        return tree.treeSHA256 == delta.treeSHA256 ? tree : nil
    }

    /// A file's SHA-256, or a symbolic link's "link:" + the SHA-256 of where it points; nil for anything else, and
    /// for something that isn't there.
    private static func digest(of url: URL) -> String? {
        switch (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType {
        case .typeRegular:
            return FileDigest.sha256(of: url)

        case .typeSymbolicLink:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
                .map { FileDigest.sha256(of: Data($0.utf8)) }
                .map { linkPrefix + $0 }

        default:
            return nil
        }
    }

    /// Whether anything is at `url`, a symbolic link that points nowhere included.
    private static func exists(_ url: URL) -> Bool {
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
        return missing.reduce(existing.path.canonicalPath) { ($0).appendingPathComponent($1) }
    }
}

extension ProjectTreeDelta {
    /// What changed from `base` to `tree`.
    init(from base: ProjectTree, to tree: ProjectTree) {
        self.init(
            baseTreeSHA256: base.treeSHA256,
            listedBy: tree.listedBy,
            excluded: tree.excluded,
            files: tree.files.filter { base.files[$0.key] != $0.value },
            removed: base.files.keys.filter { tree.files[$0] == nil }.sorted(),
            treeSHA256: tree.treeSHA256
        )
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
