import Foundation

extension XcodeTargetSources {
    /// The projects, and local packages, the test command opens: those a workspace names, or the one project.
    static func openedProjects(
        inProjectAt root: FilePath,
        arguments: [String],
        fileManager: FileSystemManager
    ) -> Result<Opened, Failure> {
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
            return .success(Opened(container: container, projects: [container.path]))
        }
        // A project's own workspace opens that project, and a package's in `.swiftpm/xcode`, that package.
        let parent = container.path.deletingLastPathComponent
        if parent.hasSuffix(".xcodeproj") {
            return .success(Opened(container: (false, parent), projects: [parent]))
        }
        if container.path.hasSuffix("/.swiftpm/xcode/package.xcworkspace") {
            let package = parent.deletingLastPathComponent.deletingLastPathComponent
            return .success(Opened(container: container, packages: [package]))
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
        return .success(Opened(container: container, projects: projects, packages: packages))
    }
}
