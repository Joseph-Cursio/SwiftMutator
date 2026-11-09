import Foundation

extension XcodeBuildConditions {
    /// Whether a project file or build configuration file has a target build with settings from a build configuration
    /// file the scan didn't read: one outside the project, or where SwiftMutator can't tell. It goes by where each file
    /// is, not by its name, which an in-project file of the same name may have.
    static func namesAnUnreadConfigurationFile(_ buildFiles: [BuildFile]) -> Bool {
        let read = Set(buildFiles.filter { $0.name.hasSuffix(".xcconfig") }.map(\.path.canonicalPath))
        return buildFiles.contains { file in
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

    /// Where the build configuration files are that a project file's build configurations are based on: by a file
    /// reference, through its groups, or by a path in a folder Xcode syncs with its group. Nil if SwiftMutator can't
    /// tell where one is, as for a project file it can't read, or a path from a variable or a source tree of the
    /// user's.
    static func configurationFiles(ofProject file: BuildFile) -> [FilePath]? {
        // A build configuration's settings come from a file only through these.
        guard file.text.contains("baseConfigurationReference") else { return [] }
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
        let sourceRoot = projectDirectory.hasPrefix("/")
            ? projectDirectory
            : projectDirectory.isEmpty ? projectFolder : projectFolder + "/" + projectDirectory

        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] {
                parents[child] = id
            }
        }
        // Where the file or group `id` is, as Xcode resolves it. A project file is a tree, but one SwiftMutator
        // didn't write may not be, so it gives up after as many steps as there are objects.
        func location(of id: String, steps: Int = 0) -> FilePath? {
            guard steps <= objects.count, let object = objects[id] else { return nil }
            let path = object["path"] as? String ?? ""
            guard !path.contains("$") else { return nil }
            let base: FilePath?
            switch object["sourceTree"] as? String {
            case "<absolute>":
                return path.hasPrefix("/") ? path : nil
            case "SOURCE_ROOT":
                base = sourceRoot
            case "<group>":
                base = parents[id].map { location(of: $0, steps: steps + 1) } ?? (id == mainGroup ? sourceRoot : nil)
            default:
                base = nil
            }
            return base.map { path.isEmpty ? $0 : $0 + "/" + path }
        }

        var files: [FilePath] = []
        for object in objects.values {
            let reference = object["baseConfigurationReference"] as? String
            let anchor = object["baseConfigurationReferenceAnchor"] as? String
            let relativePath = object["baseConfigurationReferenceRelativePath"] as? String
            if let reference {
                guard let file = location(of: reference) else { return nil }
                files.append(file)
            }
            if anchor != nil || relativePath != nil {
                guard let anchor, let relativePath, !relativePath.contains("$"),
                      let folder = location(of: anchor)
                else {
                    return nil
                }
                files.append(relativePath.hasPrefix("/") ? relativePath : folder + "/" + relativePath)
            }
        }
        return files
    }

    /// Where the build configuration files are that a build configuration file includes, by `#include "…"` or
    /// `#include? "…"`, relative to its folder. Nil if SwiftMutator can't tell where one is, as for a path from a
    /// variable or `<DEVELOPER_DIR>`.
    static func configurationFiles(includedBy file: BuildFile) -> [FilePath]? {
        let folder = (file.path as NSString).deletingLastPathComponent
        var files: [FilePath] = []
        for line in file.text.split(whereSeparator: \.isNewline) {
            let directive = line.drop { $0 == " " || $0 == "\t" }
            guard directive.hasPrefix("#include") else { continue }
            var rest = directive.dropFirst("#include".count)
            if rest.first == "?" {
                rest = rest.dropFirst()
            }
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard rest.first == "\"" else { return nil }
            let path = String(rest.dropFirst().prefix { $0 != "\"" })
            guard !path.isEmpty, !path.hasPrefix("<"), !path.contains("$") else { return nil }
            if path.hasPrefix("/") {
                files.append(path)
            } else {
                guard !file.path.isEmpty else { return nil }
                files.append(folder + "/" + path)
            }
        }
        return files
    }
}
