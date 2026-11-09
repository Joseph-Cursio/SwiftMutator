import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The code outside the project's folder that its build uses from where it is. SwiftMutator copies only the project,
/// beside it, so a relative path names the same folder from the project and its copy, and that code is built as it is,
/// unmutated. It is the local packages the project's manifests name (`LocalPackageDependencies`), and the Xcode
/// projects and packages its workspaces reference outside it. A run says what it found once, before anything is
/// built, as a notice: such a project builds and tests as it would anyway, only without mutants in that code.
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

    /// The Xcode projects and package folders outside `projectRoot` that the workspaces among `paths`, relative to it,
    /// reference, sorted by path. A file, or a folder that is neither, isn't built, so it is left out; so is anything
    /// that doesn't exist. As for local packages, one inside the project is mutated with it, and a folder that holds
    /// the project, which also holds SwiftMutator's copy and logs, is left out. The other projects these reference are
    /// not read in turn.
    static func workspaceReferences(
        outside projectRoot: URL,
        workspaces paths: some Sequence<String>
    ) -> [LocalPackageDependencies.Dependency] {
        let root = projectRoot.standardizedFileURL.pathComponents
        var found: [String: URL] = [:]
        for path in paths where isWorkspace(path) {
            for reference in references(in: projectRoot.appendingPathComponent(path)) where isBuilt(reference) {
                let components = reference.pathComponents
                guard !components.starts(with: root), !root.starts(with: components) else { continue }
                found[reference.path] = reference
            }
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

private extension OutsideProjectCode {
    /// What the workspace file at `file` references, absolute and standardized. A `group:` location is relative to the
    /// group it is in, and a top-level one, as a `container:` location, to the folder that holds the workspace.
    /// `absolute:` is a path of its own. Any other kind, such as `self:` or `developer:`, names nothing of the
    /// project's, and nor does anything in a group with such a location.
    static func references(in file: URL) -> [URL] {
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
    private let container: URL
    /// The folder of each group the parser is in, innermost last; nil for one whose location names nothing.
    private var groups: [URL?] = []
    private(set) var references: [URL] = []

    init(container: URL) {
        self.container = container.standardizedFileURL
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

    /// The folder of the innermost group the parser is in, or the container outside every group.
    private var currentGroup: URL? {
        guard let innermost = groups.last else { return container }
        return innermost
    }

    private func resolve(_ location: String) -> URL? {
        guard let colon = location.firstIndex(of: ":") else { return nil }
        let path = String(location[location.index(after: colon)...])
        let base: URL?
        switch location[..<colon] {
        case "group":
            base = currentGroup
        case "container":
            base = container
        case "absolute":
            return URL(fileURLWithPath: path).standardizedFileURL
        default:
            return nil
        }
        guard let base else { return nil }
        return path.isEmpty ? base : base.appendingPathComponent(path).standardizedFileURL
    }
}
