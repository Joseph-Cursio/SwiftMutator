import Foundation

/// Which Swift files an Xcode project's targets compile, from its project files, so that discovery leaves out a file
/// no target compiles, as an example's or a script's, whose mutants no test could kill, with coverage or without.
/// Every target counts but a test target and an aggregate one: a file only a test target compiles is a test file, as
/// coverage takes it (`ProjectSourceFiles`). A local Swift package's folder counts whole: its own manifest says what
/// it compiles. It reads the workspace or project the test command opens, with `-workspace` or `-project` or else as
/// xcodebuild finds one, and the projects those reference.
enum XcodeTargetSources {
    /// The files and folders the targets compile from.
    struct Listing: Equatable {
        /// Each file a target compiles, by its path with its links resolved.
        var files: Set<FilePath> = []
        /// Each folder whose Swift files count, but the files named, relative to the folder: Xcode's folders synced
        /// with a group, and local packages' folders, whole, their tests included, as a run with coverage leaves
        /// them out. With its links resolved.
        var folders: [FilePath: Set<FilePath>] = [:]

        /// Whether a target compiles the file at `path`, absolute.
        func contains(_ path: FilePath) -> Bool {
            let resolved = path.canonicalPath
            return files.contains(resolved) || folders.contains { folder, excluded in
                resolved.hasPrefix(folder + "/") && !excluded.contains(String(resolved.dropFirst(folder.count + 1)))
            }
        }
    }

    /// Why the files couldn't be listed, to follow "SwiftMutator couldn't tell which files the project's targets
    /// compile: ".
    struct Failure: Error, Equatable {
        let reason: String
    }

    /// The types of target whose files are tests, not code under test.
    static let testProductTypes: Set = [
        "com.apple.product-type.bundle.unit-test", "com.apple.product-type.bundle.ui-testing",
    ]

    /// The source trees of files the build makes, outside the project, which discovery never mutates.
    private static let buildSourceTrees: Set = ["BUILT_PRODUCTS_DIR", "DERIVED_FILE_DIR", "SDKROOT", "DEVELOPER_DIR"]

    /// The files the targets compile of the projects the test command in `configuration` opens, run in the project at
    /// `root`, or why SwiftMutator can't tell.
    static func listing(
        inProjectAt root: FilePath,
        testedBy configuration: MuterConfiguration,
        fileManager: FileSystemManager
    ) -> Result<Listing, Failure> {
        let projects: [FilePath]
        var listing = Listing()
        let arguments = configuration.testCommandArguments
        switch openedProjects(inProjectAt: root, arguments: arguments, fileManager: fileManager) {
        case let .success(opened):
            projects = opened.projects
            for package in opened.packages {
                listing.folders[package.canonicalPath] = []
            }

        case let .failure(failure):
            return .failure(failure)
        }

        var read: Set<FilePath> = []
        var toRead = projects
        while let project = toRead.popLast() {
            guard read.insert(project.canonicalPath).inserted else { continue }
            let path = project + "/project.pbxproj"
            let buildFile = (try? String(contentsOfFile: path, encoding: .utf8)).map { text in
                XcodeBuildConditions.BuildFile(name: "project.pbxproj", text: text, path: path)
            }
            guard let file = buildFile.flatMap(ProjectFile.init) else {
                return .failure(Failure(reason: "\(relative(project, to: root)) has no project file it can read"))
            }
            switch add(file, of: project, to: &listing, root: root) {
            case let .success(referenced): toRead += referenced
            case let .failure(failure): return .failure(failure)
            }
        }
        if let failure = addLocalPackagesTheyDependOn(to: &listing, fileManager: fileManager, root: root) {
            return .failure(failure)
        }
        addWhatLinksInTheFoldersLeadTo(to: &listing, fileManager: fileManager)
        return .success(listing)
    }

    /// Adds to `listing` the local packages that its packages' manifests name with `.package(path:)`, at any depth:
    /// Xcode builds them too, though no project names them. Nil when they're added, or why one can't be followed.
    private static func addLocalPackagesTheyDependOn(
        to listing: inout Listing,
        fileManager: FileSystemManager,
        root: FilePath
    ) -> Failure? {
        var toRead = listing.folders.keys.filter { fileManager.fileExists(atPath: $0 + "/Package.swift") }
        var read = Set(toRead)
        while let package = toRead.popLast() {
            let url = URL(fileURLWithPath: package)
            if let manifest = LocalPackageDependencies.manifestWithAComputedPackagePath(in: url) {
                let named = relative(manifest.path, to: root.canonicalPath)
                return Failure(reason: "\(named) depends on a local package by a path it can't read")
            }
            for folder in LocalPackageDependencies.localPackageFolders(namedBy: url) {
                let resolved = folder.path.canonicalPath
                guard read.insert(resolved).inserted, fileManager.fileExists(atPath: resolved + "/Package.swift")
                else {
                    continue
                }
                listing.folders[resolved] = []
                toRead.append(resolved)
            }
        }
        return nil
    }

    /// Adds to `listing` what the links in its folders lead to outside them: SwiftPM compiles the file a link in a
    /// target's folder leads to, and every file in a folder it leads to, wherever they are, and the walk of the
    /// project lists them by their own paths too.
    private static func addWhatLinksInTheFoldersLeadTo(to listing: inout Listing, fileManager: FileSystemManager) {
        for (folder, excluded) in listing.folders {
            for path in fileManager.subpaths(atPath: folder) ?? [] where !excluded.contains(path) {
                let link = folder + "/" + path
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil else { continue }
                let target = link.canonicalPath
                if fileManager.isDirectory(atPath: target) {
                    listing.folders[target] = listing.folders[target] ?? []
                } else {
                    listing.files.insert(target)
                }
            }
        }
    }

    /// The projects, and local packages, the test command opens: those a workspace names, or the one project.
    private static func openedProjects(
        inProjectAt root: FilePath,
        arguments: [String],
        fileManager: FileSystemManager
    ) -> Result<(projects: [FilePath], packages: [FilePath]), Failure> {
        let given = XcodebuildArguments(arguments).arguments.last { argument in
            argument.kind == .option && ["-workspace", "-project"].contains(argument.name) && argument.written.count > 1
        }
        let container: (isWorkspace: Bool, path: FilePath)
        if let given {
            let path = given.written[1]
            container = (given.name == "-workspace", path.hasPrefix("/") ? path : root + "/" + path)
        } else {
            // As xcodebuild picks: the one project at the top of the folder, or else the one workspace.
            let topLevel = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            let projects = topLevel.filter { $0.hasSuffix(".xcodeproj") }
            let workspaces = topLevel.filter { $0.hasSuffix(".xcworkspace") }
            if projects.count == 1 {
                container = (false, root + "/" + projects[0])
            } else if projects.isEmpty, workspaces.count == 1 {
                container = (true, root + "/" + workspaces[0])
            } else {
                return .failure(Failure(reason: "it can't tell which project or workspace the test command opens"))
            }
        }
        guard container.isWorkspace else {
            return .success(([container.path], []))
        }
        // A project's own workspace opens that project, and a package's in `.swiftpm/xcode`, that package.
        let parent = container.path.deletingLastPathComponent
        if parent.hasSuffix(".xcodeproj") {
            return .success(([parent], []))
        }
        if container.path.hasSuffix("/.swiftpm/xcode/package.xcworkspace") {
            return .success(([], [parent.deletingLastPathComponent.deletingLastPathComponent]))
        }

        let contents = container.path + "/contents.xcworkspacedata"
        let workspace = (try? String(contentsOfFile: contents, encoding: .utf8)).map { text in
            XcodeBuildConditions.BuildFile(name: "contents.xcworkspacedata", text: text, path: contents)
        }
        guard let locations = workspace.flatMap(XcodeBuildConditions.locations(inWorkspace:)) else {
            return .failure(Failure(reason: "it can't read \(relative(container.path, to: root))"))
        }
        if let nested = locations.first(where: { $0.hasSuffix(".xcworkspace") }) {
            return .failure(Failure(reason: "the workspace names another workspace, \(relative(nested, to: root))"))
        }
        let projects = locations.filter { $0.hasSuffix(".xcodeproj") }
        let packages = locations.filter { fileManager.fileExists(atPath: $0 + "/Package.swift") }
        guard !projects.isEmpty || !packages.isEmpty else {
            return .failure(Failure(reason: "\(relative(container.path, to: root)) names no project or package"))
        }
        return .success((projects, packages))
    }

    /// Adds what `file`'s targets compile, the project file of the project at `project`, to `listing`, and gives the
    /// projects it references, whose targets it can build too.
    private static func add(
        _ file: ProjectFile,
        of project: FilePath,
        to listing: inout Listing,
        root: FilePath
    ) -> Result<[FilePath], Failure> {
        let named = relative(project, to: root)
        var referenced: [FilePath] = []
        for (id, object) in file.objects {
            switch object["isa"] as? String {
            case "PBXLegacyTarget":
                let name = object["name"] as? String ?? id
                return .failure(Failure(reason: "\(named)'s target \(name) is built by an external tool"))

            case "XCLocalSwiftPackageReference", "PBXFileReference":
                switch reference(id, of: file, named: named) {
                case let .success(.project(location)?): referenced.append(location)
                case let .success(.package(location)?): listing.folders[location.canonicalPath] = []
                case .success(nil): continue
                case let .failure(failure): return .failure(failure)
                }

            case "PBXNativeTarget", "PBXFileSystemSynchronizedRootGroup":
                if let failure = add(id, of: file, named: named, to: &listing) {
                    return .failure(failure)
                }

            default:
                continue
            }
        }
        return .success(referenced)
    }

    /// What an object of a project file references that has targets of its own: a local package, or another project.
    private enum Reference {
        case project(FilePath)
        case package(FilePath)
    }

    /// Adds what the target or synced folder `id` of `file` gives `listing`: a target's own files, unless it's a test
    /// target (`add(target:of:named:to:)`), and the files a folder's exceptions add to targets that don't own it
    /// (`addExceptionsAdding(from:of:named:to:)`).
    private static func add(_ id: String, of file: ProjectFile, named: String, to listing: inout Listing) -> Failure? {
        let object = file.objects[id] ?? [:]
        guard object["isa"] as? String == "PBXNativeTarget" else {
            return addExceptionsAdding(from: id, of: file, named: named, to: &listing)
        }
        guard !testProductTypes.contains(object["productType"] as? String ?? "") else { return nil }
        return add(target: id, of: file, named: named, to: &listing)
    }

    /// What the object `id` of `file`, the project file of the project `named`, references: a local package, by a
    /// package reference or as a folder in a group, or another project; nil for anything else.
    private static func reference(_ id: String, of file: ProjectFile, named: String) -> Result<Reference?, Failure> {
        let object = file.objects[id] ?? [:]
        if object["isa"] as? String == "XCLocalSwiftPackageReference" {
            guard let path = object["relativePath"] as? String, !path.contains("$") else {
                return .failure(Failure(reason: "\(named) has a local package it can't place"))
            }
            let folder = path.hasPrefix("/") ? path : file.sourceRoot + "/" + path
            return .success(.package(XcodeBuildConditions.lexicallyNormalized(folder)))
        }
        let type = object["lastKnownFileType"] as? String ?? object["explicitFileType"] as? String
        guard type == "wrapper.pb-project" || type == "wrapper" || type == "folder" else { return .success(nil) }
        guard let location = file.location(of: id) else {
            return .failure(Failure(reason: "\(named) references a project or folder it can't place"))
        }
        if type == "wrapper.pb-project" {
            return .success(.project(location))
        }
        let isAPackage = FileManager.default.fileExists(atPath: location + "/Package.swift")
        return .success(isAPackage ? .package(location) : nil)
    }

    /// Adds the Swift files the target `id` of `file` compiles to `listing`: those its Sources phases name, and those
    /// in the folders synced with its groups, but the ones its exceptions take out. A file another target's exception
    /// adds to it is added with that target. Nil when they're added, or why one can't be placed.
    private static func add(
        target id: String,
        of file: ProjectFile,
        named project: String,
        to listing: inout Listing
    ) -> Failure? {
        let target = file.objects[id] ?? [:]
        let name = target["name"] as? String ?? id
        let cantPlace = { (what: String) in Failure(reason: "it can't place \(what) of \(project)'s target \(name)") }
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { file.objects[$0] }
        for phase in phases where phase["isa"] as? String == "PBXSourcesBuildPhase" {
            for buildFile in (phase["files"] as? [String] ?? []).compactMap({ file.objects[$0] }) {
                guard let reference = buildFile["fileRef"] as? String, let object = file.objects[reference],
                      (object["path"] as? String)?.hasSuffix(".swift") == true
                else {
                    continue
                }
                if buildSourceTrees.contains(object["sourceTree"] as? String ?? "") { continue }
                guard let location = file.location(of: reference) else {
                    return cantPlace("a file, \(object["path"] as? String ?? reference),")
                }
                listing.files.insert(location.canonicalPath)
            }
        }

        return addFoldersSynced(withGroupsOf: id, of: file, to: &listing, cantPlace: cantPlace)
    }

    /// `path` relative to `root`, for a reason to name it by.
    private static func relative(_ path: FilePath, to root: FilePath) -> FilePath {
        RepoRelativePath.of(path, under: URL(fileURLWithPath: root))
    }
}
