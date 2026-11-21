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
    /// in a folder below, isn't the project's own. More than one of the kind that wins can't be chosen between: the
    /// refusal says `--workspace` or `--project` can name one when `namingFlags`, as for a run.
    static func find(among topLevel: [URL], namingFlags: Bool = false) throws -> Self? {
        let workspaces = topLevel.filter { $0.pathExtension == "xcworkspace" }
        let projects = topLevel.filter { $0.pathExtension == "xcodeproj" }
        if workspaces.count > 1 {
            throw ambiguity(workspaces, kind: "workspace", namingFlags: namingFlags)
        }
        if let workspace = workspaces.first {
            return .workspace(workspace)
        }
        if projects.count > 1 {
            throw ambiguity(projects, kind: "project", namingFlags: namingFlags)
        }
        return projects.first.map(Self.project)
    }

    /// The workspace or project `given` names, as `--workspace` and `--project` do, with its path relative to `folder`,
    /// of those at the top of the folder. Refused when it isn't one of them.
    static func named(
        _ given: (option: String, path: String),
        among topLevel: [URL],
        in folder: URL
    ) throws -> Self {
        let isWorkspace = given.option == "-workspace"
        let wanted = URL(fileURLWithPath: given.path, relativeTo: folder).standardizedFileURL.path
        let found = topLevel.first { url in
            url.pathExtension == (isWorkspace ? "xcworkspace" : "xcodeproj") && url.standardizedFileURL.path == wanted
        }
        guard let found else {
            let flag = isWorkspace ? "--workspace" : "--project"
            let kind = isWorkspace ? "workspace" : "project"
            throw MuterError.literal(
                reason: "`\(flag) \(given.path)` names no Xcode \(kind) at the top of the project's folder, where "
                    + "SwiftMutator works out the test command from without "
                    + "\(MuterConfiguration.fileNameWithExtension)."
            )
        }
        return isWorkspace ? .workspace(found) : .project(found)
    }

    private static func ambiguity(_ candidates: [URL], kind: String, namingFlags: Bool) -> MuterError {
        let names = candidates.map(\.lastPathComponent).sorted().joined(separator: ", ")
        let flag = namingFlags ? "Name one with `--\(kind) <path>`, or write" : "Write"
        return .literal(
            reason: "There is more than one Xcode \(kind) in the project's folder (\(names)), so SwiftMutator can't "
                + "tell which one runs your tests. \(flag) \(MuterConfiguration.fileNameWithExtension) yourself: "
                + "see Configuration in SwiftMutator's README."
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
