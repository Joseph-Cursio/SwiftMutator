import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The code outside the project's folder that its build uses from where it is. SwiftMutator copies only the project,
/// beside it, so a relative path names the same folder from the project and its copy, and that code is built as it is,
/// unmutated. It is the local packages the project's manifests name (`LocalPackageDependencies`), and the Xcode
/// projects and packages its workspaces reference outside it. A run says what it found once, before anything is
/// built, as a notice: such a project builds and tests as it would anyway, only without mutants in that code.
///
/// An absolute path names the same folder from the copy too, so code inside the project that a workspace or manifest
/// names by one is also built from the project, unmutated. That is worse: its mutants are made in the copy, but never
/// built, so they survive. A run warns of it, also once.
enum OutsideProjectCode {
    /// The paths relative to `projectRoot`, which start with `../`, of `localPackages`, and of the Xcode projects and
    /// packages outside it that the workspaces among `paths`, relative to it, reference, without duplicates and sorted.
    static func paths(
        in projectRoot: URL,
        listed paths: some Sequence<String>,
        localPackages: [LocalPackageDependencies.Dependency]
    ) -> [String] {
        let references = workspaceReferences(outside: projectRoot, workspaces: paths)
        return Set((localPackages + references).map(\.relativePath)).sorted()
    }

    /// The Xcode projects and package folders inside `projectRoot` that the workspaces and manifests among `paths`,
    /// relative to it, name by an absolute path, by their paths relative to it, without duplicates and sorted.
    static func namedByAbsolutePath(in projectRoot: URL, listed paths: some Sequence<String>) -> [String] {
        let paths = Array(paths)
        let root = projectRoot.standardizedFileURL.pathComponents
        let packages = LocalPackageDependencies.namedByAbsolutePath(inside: projectRoot, manifests: paths)
        let references = builtReferences(in: projectRoot, workspaces: paths).compactMap { reference in
            let components = reference.url.pathComponents
            return reference.isAbsolute && components.count > root.count && components.starts(with: root)
                ? reference.url
                : nil
        }
        return Set((packages + references).map {
            LocalPackageDependencies.relativePath(of: $0.pathComponents, from: root)
        })
        .sorted()
    }

    /// The Xcode projects and package folders outside `projectRoot` that the workspaces among `paths`, relative to it,
    /// reference, sorted by path. As for local packages, one inside the project is left to `namedByAbsolutePath`, and
    /// a folder that holds the project, which also holds SwiftMutator's copy and logs, is left out. The other projects
    /// these reference are not read in turn.
    static func workspaceReferences(
        outside projectRoot: URL,
        workspaces paths: some Sequence<String>
    ) -> [LocalPackageDependencies.Dependency] {
        let root = projectRoot.standardizedFileURL.pathComponents
        var found: [String: URL] = [:]
        for reference in builtReferences(in: projectRoot, workspaces: paths) {
            let components = reference.url.pathComponents
            guard !components.starts(with: root), !root.starts(with: components) else { continue }
            found[reference.url.path] = reference.url
        }
        return found.values.sorted { $0.path < $1.path }.map {
            .init(url: $0, relativePath: LocalPackageDependencies.relativePath(of: $0.pathComponents, from: root))
        }
    }

    /// A workspace's `contents.xcworkspacedata`, but not that of the workspace inside an Xcode project
    /// (`project.xcworkspace`), which only references the project itself.
    static func isWorkspace(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count >= 2
            && components[components.count - 1] == "contents.xcworkspacedata"
            && components[components.count - 2].hasSuffix(".xcworkspace")
            && !components.dropLast(2).contains { $0.hasSuffix(".xcodeproj") }
    }
}

/// A path a workspace references, absolute and standardized, and whether the workspace names it by an absolute path,
/// which the copy's workspace names too.
private struct WorkspaceReference {
    let url: URL
    let isAbsolute: Bool
}

private extension OutsideProjectCode {
    /// What the workspaces among `paths`, relative to `projectRoot`, reference that is built: a file, or a folder that
    /// is neither an Xcode project nor a package, isn't, and nor is anything that doesn't exist.
    static func builtReferences(in projectRoot: URL, workspaces paths: some Sequence<String>) -> [WorkspaceReference] {
        paths.filter(isWorkspace).flatMap { path in
            references(in: projectRoot.appendingPathComponent(path)).filter { isBuilt($0.url) }
        }
    }

    /// What the workspace file at `file` references. A `group:` location is relative to the group it is in, and a
    /// top-level one, as a `container:` location, to the folder that holds the workspace. `absolute:` is a path of
    /// its own, and so is a `group:` location in a group with one. Any other kind, such as `self:` or `developer:`,
    /// names nothing of the project's, and nor does anything in a group with such a location.
    static func references(in file: URL) -> [WorkspaceReference] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let reader = WorkspaceReader(container: file.deletingLastPathComponent().deletingLastPathComponent())
        let parser = XMLParser(data: data)
        parser.delegate = reader
        // A workspace that doesn't parse keeps what was read before the error.
        parser.parse()
        return reader.references
    }

    /// An Xcode project, or a folder that holds a package manifest.
    static func isBuilt(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            return false
        }
        if url.pathExtension == "xcodeproj" {
            return true
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.contains(where: LocalPackageDependencies.isManifest)
    }
}

/// Reads a workspace's `FileRef` locations, resolving each against the `Group`s it is in.
private final class WorkspaceReader: NSObject, XMLParserDelegate {
    private let container: WorkspaceReference
    /// Where each group the parser is in is, innermost last; nil for one whose location names nothing.
    private var groups: [WorkspaceReference?] = []
    private(set) var references: [WorkspaceReference] = []

    init(container: URL) {
        self.container = WorkspaceReference(url: container.standardizedFileURL, isAbsolute: false)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Group":
            // A group without a location is only a name, so its references are relative to the group it is in.
            if let location = attributeDict["location"] {
                groups.append(resolve(location))
            } else {
                groups.append(currentGroup)
            }
        case "FileRef":
            if let location = attributeDict["location"], let reference = resolve(location) {
                references.append(reference)
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Group", !groups.isEmpty {
            groups.removeLast()
        }
    }

    /// Where the innermost group the parser is in is, or the container outside every group.
    private var currentGroup: WorkspaceReference? {
        guard let innermost = groups.last else { return container }
        return innermost
    }

    private func resolve(_ location: String) -> WorkspaceReference? {
        guard let colon = location.firstIndex(of: ":") else { return nil }
        let path = String(location[location.index(after: colon)...])
        let base: WorkspaceReference?
        switch location[..<colon] {
        case "group":
            base = currentGroup
        case "container":
            base = container
        case "absolute":
            return WorkspaceReference(url: URL(fileURLWithPath: path).standardizedFileURL, isAbsolute: true)
        default:
            return nil
        }
        guard let base else { return nil }
        return path.isEmpty
            ? base
            : WorkspaceReference(
                url: base.url.appendingPathComponent(path).standardizedFileURL,
                isAbsolute: base.isAbsolute
            )
    }
}
