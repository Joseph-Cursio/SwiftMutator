import Foundation

/// The local packages a project builds from outside its own folder: those its package manifests name with
/// `.package(path:)`, and its Xcode projects with a local package reference, each by a literal path, and those theirs
/// name in turn. SwiftMutator copies only the project, beside it, so a relative path names the same folder from the
/// project and its copy, and every session builds whatever that folder holds then. A path a manifest computes, and any
/// other file outside the project that a build or a test reads, isn't found.
enum LocalPackageDependencies {
    struct Dependency: Equatable {
        /// The package's folder, absolute and standardized.
        let url: URL
        /// Its path relative to the project, which starts with `../`.
        let relativePath: String
    }

    /// The local packages outside `projectRoot` that the manifests among `paths`, relative to it, depend on, directly
    /// or through each other, sorted by path. A package inside the project is listed with it, and a folder that holds
    /// the project, which also holds SwiftMutator's copy and logs, is left out.
    static func outside(_ projectRoot: URL, manifests paths: some Sequence<String>) -> [Dependency] {
        let root = projectRoot.standardizedFileURL.pathComponents
        var manifests = paths.filter(isManifest).map { projectRoot.appendingPathComponent($0) }
        var found: [String: URL] = [:]
        while let manifest = manifests.popLast() {
            for folder in packageFolders(namedIn: manifest) {
                let components = folder.pathComponents
                guard !components.starts(with: root), !root.starts(with: components), found[folder.path] == nil else {
                    continue
                }
                found[folder.path] = folder
                manifests += packageManifests(in: folder)
            }
        }
        return found.values
            .sorted { $0.path < $1.path }
            .map { Dependency(url: $0, relativePath: relativePath(of: $0.pathComponents, from: root)) }
    }

    /// `Package.swift`, `Package@swift-*.swift`, or an Xcode project's `project.pbxproj`.
    static func isManifest(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last else { return false }
        if name == "project.pbxproj" {
            return components.count >= 2 && components[components.count - 2].hasSuffix(".xcodeproj")
        }
        return name == "Package.swift" || name.hasPrefix("Package@swift-") && name.hasSuffix(".swift")
    }
}

private extension LocalPackageDependencies {
    /// `.package(path: "…")`, and `.package(name: "…", path: "…")`.
    static let packagePath = #"\.package\s*\(\s*(?:name\s*:\s*"[^"]*"\s*,\s*)?path\s*:\s*"((?:[^"\\]|\\.)*)""#
    /// An Xcode project's local package reference: `relativePath = ../Core;`, or quoted.
    static let xcodeReference =
        #"isa\s*=\s*XCLocalSwiftPackageReference\s*;\s*relativePath\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;\s]+))\s*;"#
    /// A block comment, or a line that is only a comment: a dependency commented out is no dependency.
    static let comment = #"(?m)/\*[\s\S]*?\*/|^[ \t]*//.*$"#

    /// The folders the manifest at `manifest` names, standardized: a package manifest's paths are relative to its
    /// folder, and an Xcode project's to the folder that holds the project.
    static func packageFolders(namedIn manifest: URL) -> [URL] {
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return [] }
        let isXcodeProject = manifest.lastPathComponent == "project.pbxproj"
        let base = isXcodeProject
            ? manifest.deletingLastPathComponent().deletingLastPathComponent()
            : manifest.deletingLastPathComponent()
        let paths = isXcodeProject
            ? captures(of: xcodeReference, in: text)
            : captures(of: packagePath, in: replacing(comment, in: text))
        return paths.map { path in
            let expanded = (path as NSString).expandingTildeInPath
            let folder = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded)
                : base.appendingPathComponent(expanded)
            return folder.standardizedFileURL
        }
    }

    /// The package manifests at the top of `folder`.
    static func packageManifests(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter(isManifest).sorted().map { folder.appendingPathComponent($0) }
    }

    /// The first group of `pattern` that took part in each match in `text`, unescaped.
    static func captures(of pattern: String, in text: String) -> [String] {
        let expression = NSRegularExpression.regexWithPattern(pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            (1..<match.numberOfRanges)
                .lazy
                .compactMap { Range(match.range(at: $0), in: text) }
                .first
                .map { unescaped(String(text[$0])) }
        }
    }

    /// A quoted string's contents, with each `\"` and `\\` unescaped.
    static func unescaped(_ quoted: String) -> String {
        quoted.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\\"#, with: #"\"#)
    }

    static func replacing(_ pattern: String, in text: String) -> String {
        NSRegularExpression.regexWithPattern(pattern)
            .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// `components`' path from `root`'s, as `../` steps up and then down.
    static func relativePath(of components: [String], from root: [String]) -> String {
        let shared = zip(root, components).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: root.count - shared) + components.dropFirst(shared))
            .joined(separator: "/")
    }
}
