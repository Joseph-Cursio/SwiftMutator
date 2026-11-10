import Foundation

/// Any key of a manifest's JSON, for a setting whose keys aren't all known.
private struct ManifestKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) {
        stringValue = name
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

/// The fields of `swift package dump-package` that say what a target compiles with.
struct PackageManifest: Decodable {
    let targets: [Target]
    let traits: [Trait]?
    let toolsVersion: ToolsVersion?
    let swiftLanguageVersions: [String]?

    struct ToolsVersion: Decodable {
        // swiftlint:disable:next identifier_name
        let _version: String
    }

    /// The language mode of a target that sets none: the latest of `swiftLanguageModes`, as a compiler that has
    /// them all builds in, or else the one its tools version sets. Nil for a mode SwiftMutator doesn't know, which
    /// may be the latest, or a tools version before 5.
    var defaultLanguageMode: LanguageMode? {
        if let written = swiftLanguageVersions, !written.isEmpty {
            let modes = written.compactMap(LanguageMode.init)
            return modes.count == written.count ? modes.max() : nil
        }
        return toolsVersionsLanguageMode
    }

    /// The language mode the tools version sets, which a plugin is built in whatever `swiftLanguageModes` says.
    var toolsVersionsLanguageMode: LanguageMode? {
        switch toolsVersion?._version.split(separator: ".").first {
        case "5": return .swift5
        case "6": return .swift6
        default: return nil
        }
    }

    struct Trait: Decodable {
        let name: String
    }

    struct Target: Decodable {
        let name: String
        let type: String?
        let settings: [Setting]?
    }

    struct Setting: Decodable {
        let tool: String
        let kind: Kind
        let condition: Condition?
    }

    struct Kind: Decodable {
        let define: Payload<String>?
        let unsafeFlags: Payload<[String]>?
        /// Whether the setting sets the language mode: `swiftLanguageMode`, `swiftLanguageVersion` as tools
        /// versions before 6 write it, or another spelling of either.
        let setsLanguageMode: Bool
        /// The mode it sets; nil if it sets none, or one SwiftMutator can't read.
        let languageMode: LanguageMode?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ManifestKey.self)
            define = try container.decodeIfPresent(Payload<String>.self, forKey: ManifestKey("define"))
            unsafeFlags = try container.decodeIfPresent(Payload<[String]>.self, forKey: ManifestKey("unsafeFlags"))
            let modeKeys = container.allKeys.filter { key in
                let name = key.stringValue.lowercased()
                return name.contains("languagemode") || name.contains("languageversion")
            }
            setsLanguageMode = !modeKeys.isEmpty
            let known = modeKeys.count == 1 && ["swiftLanguageMode", "swiftLanguageVersion"]
                .contains(modeKeys[0].stringValue)
            languageMode = known
                ? (try? container.decode(Payload<String>.self, forKey: modeKeys[0])).flatMap { LanguageMode($0._0) }
                : nil
        }
    }

    // swiftlint:disable:next identifier_name
    struct Payload<Value: Decodable>: Decodable { let _0: Value }

    struct Condition: Decodable {
        let config: String?
        let platformNames: [String]?
        let traits: [String]?
    }
}
