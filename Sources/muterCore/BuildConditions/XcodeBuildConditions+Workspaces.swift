import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads a workspace's `FileRef` locations, resolving each against the `Group`s it is in.
private final class WorkspaceLocations: NSObject, XMLParserDelegate {
    private let container: FilePath
    /// Where each group the parser is in is, innermost last; nil for one SwiftMutator can't place.
    private var groups: [FilePath?] = []
    private(set) var locations: [FilePath] = []
    private(set) var hasAnUnknownLocation = false

    init(container: FilePath) {
        self.container = container
    }

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Group":
            // A group without a location is only a name, so its references are relative to the group it is in.
            groups.append(attributeDict["location"].map(resolve) ?? currentGroup)

        case "FileRef":
            guard let location = attributeDict["location"] else { return }
            if location.hasPrefix("self:") {
                // The project or workspace itself, or something in it.
                let path = location.dropFirst("self:".count)
                hasAnUnknownLocation = hasAnUnknownLocation || path.hasPrefix("/") || path.contains("..")
                return
            }
            if let resolved = resolve(location) {
                locations.append(resolved)
            } else {
                hasAnUnknownLocation = true
            }

        default:
            break
        }
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        if elementName == "Group", !groups.isEmpty {
            groups.removeLast()
        }
    }

    private var currentGroup: FilePath? {
        groups.last ?? container
    }

    private func resolve(_ location: String) -> FilePath? {
        guard let colon = location.firstIndex(of: ":") else { return nil }
        let path = String(location[location.index(after: colon)...])
        guard !path.contains("$") else { return nil }
        let kind = location[..<colon]
        if kind == "absolute" {
            return path.hasPrefix("/") ? path : nil
        }
        // Only an `absolute:` location is a path of its own.
        guard !path.hasPrefix("/") else { return nil }
        let base: FilePath?
        switch kind {
        case "group":
            base = currentGroup

        case "container":
            base = container

        default:
            return nil
        }
        return base.map { path.isEmpty ? $0 : $0 + "/" + path }
    }
}

extension XcodeBuildConditions {
    /// The build configuration files the command has every target build with: each that `-xcconfig` names, and
    /// `XCODE_XCCONFIG_FILE`'s, by where they are from `root`, which the command runs in, as written. xcodebuild takes
    /// each `..` off the folder before it, whatever links there are, so the caller needs both forms read. Nil if a
    /// `-xcconfig` names none, or one is from a variable.
    static func configurationFiles(
        ofCommand arguments: [String],
        _ environment: [String: String],
        root: FilePath
    ) -> [FilePath]? {
        var named: [String] = []
        for (index, argument) in arguments.enumerated() where argument == "-xcconfig" {
            guard index + 1 < arguments.count else { return nil }
            named.append(arguments[index + 1])
        }
        if let file = environment["XCODE_XCCONFIG_FILE"] {
            named.append(file)
        }
        guard !named.contains(where: { $0.isEmpty || $0.contains("$") || $0.hasPrefix("~") }) else { return nil }
        return named.map { $0.hasPrefix("/") ? $0 : root + "/" + $0 }
    }

    /// Whether a workspace references a project or package whose build files the scan didn't read, as one outside
    /// the project, or where SwiftMutator can't tell: by a kind of location it doesn't follow, as `developer:`, or in
    /// a workspace it can't read. A project's are its project file, and a package's its manifest. A path is taken
    /// both as Xcode may resolve it, with each `..` taking off the folder before it, and as the system does, through
    /// links, and must be read both ways.
    static func referencesAnUnreadProject(
        _ workspace: BuildFile,
        readProjects: Set<FilePath>,
        readManifests: Set<FilePath>
    ) -> Bool {
        guard let references = locations(inWorkspace: workspace) else { return true }
        return references.contains { reference in
            [reference, lexicallyNormalized(reference)].contains { path in
                if path.hasSuffix(".xcodeproj") {
                    return !readProjects.contains((path + "/project.pbxproj").canonicalPath)
                }
                // A workspace in a workspace is no reference Xcode builds from, but SwiftMutator doesn't follow it.
                if path.hasSuffix(".xcworkspace") {
                    return true
                }
                let manifest = path + "/Package.swift"
                return FileManager.default.fileExists(atPath: manifest)
                    && !readManifests.contains(manifest.canonicalPath)
            }
        }
    }

    /// Where each `FileRef` in a workspace is, as written, through the `Group`s it is in: a `group:` location is
    /// relative to its group, and a top-level one, as a `container:` location, to the folder that holds the
    /// workspace; an `absolute:` one is a path of its own. Nil if the workspace doesn't parse, or has a location of
    /// another kind, other than a `self:` one in the workspace itself, as a project's own workspace has.
    static func locations(inWorkspace file: BuildFile) -> [FilePath]? {
        guard !file.path.isEmpty else { return nil }
        let container = file.path.deletingLastPathComponent.deletingLastPathComponent
        let reader = WorkspaceLocations(container: container)
        let parser = XMLParser(data: Data(file.text.utf8))
        parser.delegate = reader
        guard parser.parse(), !reader.hasAnUnknownLocation else { return nil }
        return reader.locations
    }
}
