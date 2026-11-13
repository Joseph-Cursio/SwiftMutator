import Foundation

/// The workspace or project at the top of the project's folder that `init` writes the test command for.
enum XcodeContainer: Equatable {
    case workspace(URL)
    case project(URL)

    var url: URL {
        switch self {
        case let .workspace(url), let .project(url): url
        }
    }

    var argument: String {
        switch self {
        case .workspace: "-workspace"
        case .project: "-project"
        }
    }

    /// The name without its extension, as `App` is `App.xcworkspace`'s.
    var name: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// The workspace, else the project, of those at the top of the folder: one a dependency's or an example app's,
    /// in a folder below, isn't the project's own. More than one of the kind that wins can't be chosen between.
    static func find(among topLevel: [URL]) throws -> Self? {
        let workspaces = topLevel.filter { $0.pathExtension == "xcworkspace" }
        let projects = topLevel.filter { $0.pathExtension == "xcodeproj" }
        if workspaces.count > 1 {
            throw ambiguity(workspaces, kind: "workspace")
        }
        if let workspace = workspaces.first {
            return .workspace(workspace)
        }
        if projects.count > 1 {
            throw ambiguity(projects, kind: "project")
        }
        return projects.first.map(Self.project)
    }

    private static func ambiguity(_ candidates: [URL], kind: String) -> MuterError {
        let names = candidates.map(\.lastPathComponent).sorted().joined(separator: ", ")
        return .literal(
            reason: "There is more than one Xcode \(kind) in the project's folder (\(names)), and init can't tell "
                + "which one runs your tests, so it wrote nothing. Write \(MuterConfiguration.fileNameWithExtension) "
                + "yourself: see Configuration in SwiftMutator's README."
        )
    }

    /// The projects whose build settings say what platform it builds for: the project itself, or those a
    /// workspace's `contents.xcworkspacedata` names, wherever its groups put them, and the projects beside it.
    func projectFiles(besides topLevel: [URL]) -> [URL] {
        switch self {
        case let .project(url):
            return [url]

        case let .workspace(url):
            let contents = url.appendingPathComponent("contents.xcworkspacedata").path
            let workspace = XcodeBuildConditions.BuildFile(
                name: "contents.xcworkspacedata",
                text: (try? String(contentsOfFile: contents, encoding: .utf8)) ?? "",
                path: contents
            )
            let named = (XcodeBuildConditions.locations(inWorkspace: workspace) ?? [])
                .filter { $0.hasSuffix(".xcodeproj") }
                .map { URL(fileURLWithPath: $0) }
            return named + topLevel.filter { $0.pathExtension == "xcodeproj" }
        }
    }
}
