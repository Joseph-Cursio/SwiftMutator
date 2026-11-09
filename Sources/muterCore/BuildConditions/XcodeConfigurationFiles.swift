import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

extension XcodeBuildConditions {
    /// Whether a project file or build configuration file has a target build with settings from a build configuration
    /// file the scan didn't read: one outside the project, or where SwiftMutator can't tell, as when a build file moves
    /// the folder paths are resolved from. It goes by where each file is, not by its name, which an in-project file of
    /// the same name may have.
    static func namesAnUnreadConfigurationFile(_ buildFiles: [BuildFile]) -> Bool {
        let read = Set(buildFiles.filter { $0.name.hasSuffix(".xcconfig") }.map(\.path.canonicalPath))
        let movesTheProjectFolder = buildFiles.contains { file in
            buildSettings(in: file).map { $0.contains { projectFolderSettings.contains($0.name) } } ?? true
        }
        return movesTheProjectFolder || buildFiles.contains { file in
            let named: [FilePath]?
            if file.name == "project.pbxproj" {
                named = configurationFiles(ofProject: file)
            } else if file.name.hasSuffix(".xcconfig") {
                named = configurationFiles(includedBy: file)
            } else {
                return false
            }
            return named.map { !$0.allSatisfy { read.contains($0.canonicalPath) } } ?? true
        }
    }

    /// The settings that say where a project's folder is, which paths in its project file are resolved from.
    static let projectFolderSettings: Set = ["PROJECT_DIR", "SRCROOT", "SOURCE_ROOT"]

    /// Where the build configuration files are that a project file's build configurations are based on: by a file
    /// reference, through its groups, or by a path in a folder Xcode syncs with its group. Nil if SwiftMutator can't
    /// tell where one is, as for a project file it can't read, or a path from a variable or a source tree of the
    /// user's.
    static func configurationFiles(ofProject file: BuildFile) -> [FilePath]? {
        // A build configuration's settings come from a file only through these.
        guard file.text.contains("baseConfigurationReference") else { return [] }
        guard let project = ProjectFile(file) else { return nil }

        var files: [FilePath] = []
        for object in project.objects.values {
            let reference = object["baseConfigurationReference"] as? String
            let anchor = object["baseConfigurationReferenceAnchor"] as? String
            let relativePath = object["baseConfigurationReferenceRelativePath"] as? String
            if let reference {
                guard let file = project.location(of: reference) else { return nil }
                files.append(file)
            }
            if anchor != nil || relativePath != nil {
                guard let anchor, let relativePath, !relativePath.contains("$"),
                      let folder = project.location(of: anchor)
                else {
                    return nil
                }
                let path = relativePath.hasPrefix("/") ? relativePath : folder + "/" + relativePath
                files.append(lexicallyNormalized(path))
            }
        }
        return files
    }

    /// Where the projects are that a project file references. Nil if SwiftMutator can't tell where one is.
    static func referencedProjects(ofProject file: BuildFile) -> [FilePath]? {
        guard file.text.contains("wrapper.pb-project") else { return [] }
        guard let project = ProjectFile(file) else { return nil }

        var projects: [FilePath] = []
        for (id, object) in project.objects {
            let type = object["lastKnownFileType"] as? String ?? object["explicitFileType"] as? String
            guard type == "wrapper.pb-project" else { continue }
            guard let location = project.location(of: id) else { return nil }
            projects.append(location)
        }
        return projects
    }

    /// Where the build configuration files are that a build configuration file includes, by `#include "…"` or
    /// `#include? "…"`, relative to its folder. Nil if SwiftMutator can't tell where one is, as for a path from a
    /// variable or `<DEVELOPER_DIR>`, or for a line Xcode may read as a directive that it can't.
    static func configurationFiles(includedBy file: BuildFile) -> [FilePath]? {
        let blanks: Set<Character> = [" ", "\t", "\u{0B}", "\u{0C}"]
        let folder = (file.path as NSString).deletingLastPathComponent
        var files: [FilePath] = []
        for line in file.text.split(whereSeparator: \.isNewline) {
            let directive = line.drop { blanks.contains($0) }
            guard directive.first == "#" else { continue }
            // Xcode skips blanks between the `#` and the directive's name.
            var rest = directive.dropFirst().drop { blanks.contains($0) }
            guard rest.hasPrefix("include") else { return nil }
            rest = rest.dropFirst("include".count)
            if rest.first == "?" {
                rest = rest.dropFirst()
            }
            rest = rest.drop { blanks.contains($0) }
            guard rest.first == "\"" else { return nil }
            let path = String(rest.dropFirst().prefix { $0 != "\"" })
            guard !path.isEmpty, !path.hasPrefix("<"), !path.contains("$") else { return nil }
            if path.hasPrefix("/") {
                files.append(path)
            } else {
                guard !file.path.isEmpty else { return nil }
                // Xcode follows an include's path through links as it goes, as `canonicalPath` does.
                files.append(folder + "/" + path)
            }
        }
        return files
    }

    /// The build settings a project file or build configuration file assigns, by name without the conditions in
    /// brackets, with their values as written. Nil if SwiftMutator can't read them all.
    static func buildSettings(in file: BuildFile) -> [(name: String, value: String)]? {
        if file.name == "project.pbxproj" {
            if let project = ProjectFile(file) {
                return project.objects.values.flatMap { object in
                    (object["buildSettings"] as? [String: Any] ?? [:]).map { key, value in
                        let value = (value as? [String])?.joined(separator: " ") ?? value as? String ?? ""
                        return (settingName(key), value)
                    }
                }
            }
            // Not a project file Xcode wrote, so read as lines, unless a value is a list, which spans several.
            let settings = settingAssignments(inLines: file.text)
            return settings.contains { $0.value.hasPrefix("(") } ? nil : settings
        }
        return file.name.hasSuffix(".xcconfig") ? settingAssignments(inLines: file.text) : []
    }

    /// Each `NAME = value`, `NAME[sdk=…] = value` or `"NAME[…]" = "value";` on a line of its own.
    private static func settingAssignments(inLines text: String) -> [(name: String, value: String)] {
        let isPartOfAName: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = line.drop { $0 == " " || $0 == "\t" }
            if rest.first == "\"" {
                rest = rest.dropFirst()
            }
            let name = String(rest.prefix(while: isPartOfAName))
            guard !name.isEmpty else { return nil }
            rest = rest.dropFirst(name.count)
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                rest = rest[rest.index(after: close)...]
            }
            if rest.first == "\"" {
                rest = rest.dropFirst()
            }
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard rest.first == "=" else { return nil }
            var value = rest.dropFirst().components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") {
                value.removeLast()
            }
            return (name, value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
        }
    }

    private static func settingName(_ key: String) -> String {
        String(key.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).prefix { $0 != "[" })
    }

    /// `path` with each `..` taking off the folder before it, as Xcode resolves a project file's paths, whatever links
    /// there are on the way.
    static func lexicallyNormalized(_ path: FilePath) -> FilePath {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !path.hasPrefix("/") {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        return (path.hasPrefix("/") ? "/" : "") + components.joined(separator: "/")
    }
}

/// A project file's objects, and where its files and groups are.
private struct ProjectFile {
    let objects: [String: [String: Any]]
    private let mainGroup: String
    private let sourceRoot: FilePath
    /// Each object's groups: one, in a project file Xcode wrote.
    private let parents: [String: Set<String>]

    init?(_ file: XcodeBuildConditions.BuildFile) {
        guard !file.path.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: Data(file.text.utf8), format: nil),
              let project = plist as? [String: Any],
              let objects = project["objects"] as? [String: [String: Any]],
              let projectObject = (project["rootObject"] as? String).flatMap({ objects[$0] }),
              let mainGroup = projectObject["mainGroup"] as? String
        else {
            return nil
        }
        let projectFolder = ((file.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let projectDirectory = projectObject["projectDirPath"] as? String ?? ""
        guard !projectDirectory.contains("$") else { return nil }

        self.objects = objects
        self.mainGroup = mainGroup
        sourceRoot = projectDirectory.hasPrefix("/")
            ? projectDirectory
            : projectDirectory.isEmpty ? projectFolder : projectFolder + "/" + projectDirectory
        var parents: [String: Set<String>] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] {
                parents[child, default: []].insert(id)
            }
        }
        self.parents = parents
    }

    /// Where the file or group `id` is, as Xcode resolves it; nil if SwiftMutator can't tell.
    func location(of id: String) -> FilePath? {
        unnormalizedLocation(of: id).map(XcodeBuildConditions.lexicallyNormalized)
    }

    /// A project file is a tree, but one SwiftMutator didn't write may not be, so this gives up after as many steps
    /// as there are objects, and on an object in more than one group.
    private func unnormalizedLocation(of id: String, steps: Int = 0) -> FilePath? {
        guard steps <= objects.count, let object = objects[id] else { return nil }
        let path = object["path"] as? String ?? ""
        guard !path.contains("$") else { return nil }
        // Xcode takes an absolute path as it is, whatever it is relative to.
        if path.hasPrefix("/") {
            return path
        }
        let base: FilePath?
        switch object["sourceTree"] as? String {
        case "SOURCE_ROOT":
            base = sourceRoot
        case "<group>":
            switch parents[id] {
            case nil: base = id == mainGroup ? sourceRoot : nil
            case let groups? where groups.count == 1:
                base = groups.first.flatMap { unnormalizedLocation(of: $0, steps: steps + 1) }
            default: base = nil
            }
        default:
            base = nil
        }
        return base.map { path.isEmpty ? $0 : $0 + "/" + path }
    }
}

extension XcodeBuildConditions {
    /// Whether a condition some target builds with may be put together from a setting, as `EDITION_$(EDITION)`,
    /// `$(NAME:upper)` or `$(FLAGS_$(CONFIGURATION))` make one, or come from a setting whose value SwiftMutator can't
    /// see, as `-D$(TARGET_NAME)` does: then it is a word in no build file. It follows each setting that the settings
    /// conditions are in refer to, through the build files, the command's `NAME=value` settings and the environment.
    static func mayComposeConditions(
        _ buildFiles: [BuildFile],
        _ arguments: [String],
        _ environment: [String: String]
    ) -> Bool {
        var values: [String: [String]] = [:]
        for file in buildFiles {
            guard let settings = buildSettings(in: file) else { return true }
            for (name, value) in settings {
                values[name, default: []].append(value)
            }
        }
        for argument in arguments where !argument.hasPrefix("-") {
            guard let equals = argument.firstIndex(of: "=") else { continue }
            let name = settingName(String(argument[..<equals]))
            values[name, default: []].append(String(argument[argument.index(after: equals)...]))
        }
        for (name, value) in environment {
            values[name, default: []].append(value)
        }

        var toFollow = ["SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS"]
        var followed: Set<String> = []
        while let name = toFollow.popLast() {
            guard followed.insert(name).inserted else { continue }
            for value in values[name] ?? [] {
                guard let references = plainReferences(in: value) else { return true }
                for reference in references where reference != "inherited" {
                    // One Xcode sets itself, as `TARGET_NAME` or `CURRENT_ARCH`, may differ by target.
                    guard values[reference] != nil else { return true }
                    toFollow.append(reference)
                }
            }
        }
        return false
    }

    /// The settings `value` refers to, as `$(NAME)`, `${NAME}` or `$NAME`, each a word of its own or after `-D`. Nil
    /// if one is glued to more of a name, takes an operator, as `$(NAME:upper)`, or holds another reference.
    private static func plainReferences(in value: String) -> [String]? {
        let isPartOfAName: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        let characters = Array(value)
        var names: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "$" else {
                index += 1
                continue
            }
            let name: String
            let end: Int
            let closers: [Character: Character] = ["(": ")", "{": "}"]
            if index + 1 < characters.count, let close = closers[characters[index + 1]] {
                guard let closing = characters[(index + 2)...].firstIndex(of: close) else { return nil }
                name = String(characters[(index + 2) ..< closing])
                end = closing + 1
            } else {
                name = String(characters[(index + 1)...].prefix(while: isPartOfAName))
                end = index + 1 + name.count
            }
            let before = characters[..<index]
            let gluedBefore = before.last.map(isPartOfAName) == true && Array(before.suffix(2)) != ["-", "D"]
            let gluedAfter = end < characters.count && isPartOfAName(characters[end])
            guard !name.isEmpty, name.allSatisfy(isPartOfAName), !gluedBefore, !gluedAfter else { return nil }
            names.append(name)
            index = end
        }
        return names
    }
}

extension XcodeBuildConditions {
    /// The build configuration files the command has every target build with: each that `-xcconfig` names, and
    /// `XCODE_XCCONFIG_FILE`'s, by where they are from `root`, which the command runs in. Nil if a `-xcconfig` names
    /// none, or one is from a variable.
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
        // xcodebuild opens the file as the system does, through links.
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
        let container = ((file.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let reader = WorkspaceLocations(container: container)
        let parser = XMLParser(data: Data(file.text.utf8))
        parser.delegate = reader
        guard parser.parse(), !reader.hasAnUnknownLocation else { return nil }
        return reader.locations
    }
}

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
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
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
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
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
