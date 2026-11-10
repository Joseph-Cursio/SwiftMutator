import Foundation

/// A SARIF 2.1.0 log, as GitHub code scanning reads it: one run, with only the parts SwiftMutator has something to
/// put in. Every optional part nil is left out. GitHub's page on what it reads:
/// https://docs.github.com/code-security/code-scanning/integrating-with-code-scanning/sarif-support-for-code-scanning
struct SarifLog: Codable, Equatable {
    /// The schema GitHub's documentation names.
    static let schemaURI = "https://json.schemastore.org/sarif-2.1.0.json"

    let schema: String
    let version: String
    let runs: [Run]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version
        case runs
    }

    struct Run: Codable, Equatable {
        let tool: Tool
        let invocations: [Invocation]
        /// `%SRCROOT%`, the work tree the project is in, or the project's folder outside one, as a `file://` URI,
        /// which each relative path is under; nil when the project's path isn't known.
        let originalUriBaseIds: [String: ArtifactLocation]?
        /// Always `utf16CodeUnits`, SARIF's default, said for tools that would assume another.
        let columnKind: String
        let results: [Result]
        /// How many results were left out, when some were; nil, and left out, otherwise.
        let properties: Properties?
    }

    struct Properties: Codable, Equatable {
        let resultsLeftOut: Int
    }

    struct Tool: Codable, Equatable {
        let driver: Driver
    }

    struct Driver: Codable, Equatable {
        let name: String
        let version: String
        let informationUri: String
        let rules: [Rule]
    }

    /// An operator, whose mutants are its results.
    struct Rule: Codable, Equatable {
        let id: String
        let name: String
        let shortDescription: Message
        let fullDescription: Message
        let help: Message
        let defaultConfiguration: Configuration
    }

    struct Configuration: Codable, Equatable {
        let level: Level
    }

    enum Level: String, Codable, Equatable {
        case warning
        case note
    }

    struct Message: Codable, Equatable {
        let text: String
    }

    struct Invocation: Codable, Equatable {
        let executionSuccessful: Bool
        /// Says that results were left out, when some were; nil, and left out, otherwise.
        let toolExecutionNotifications: [Notification]?
    }

    struct Notification: Codable, Equatable {
        let level: Level
        let message: Message
    }

    struct Result: Codable, Equatable {
        let ruleId: String
        let ruleIndex: Int
        let level: Level
        let message: Message
        let locations: [Location]
        let partialFingerprints: [String: String]
    }

    struct Location: Codable, Equatable {
        let physicalLocation: PhysicalLocation
    }

    struct PhysicalLocation: Codable, Equatable {
        let artifactLocation: ArtifactLocation
        let region: Region
        /// The lines the region is on, whole; nil, and left out, when the region covers them whole or they aren't
        /// known.
        let contextRegion: ContextRegion?
    }

    /// A relative `uri` with `uriBaseId` `%SRCROOT%`, or an absolute `file://` one without.
    struct ArtifactLocation: Codable, Equatable {
        let uri: String
        let uriBaseId: String?
    }

    /// From 1; the columns count UTF-16 code units, and the end is just past the mutant's code.
    struct Region: Codable, Equatable {
        let startLine: Int
        let startColumn: Int
        let endLine: Int
        let endColumn: Int
        /// The code the region covers, as its file holds it; nil, and left out, when not known.
        let snippet: Snippet?
    }

    /// Lines around a region, from 1: SARIF's place for the text beside a region's own.
    struct ContextRegion: Codable, Equatable {
        let startLine: Int
        let endLine: Int
        let snippet: Snippet
    }

    struct Snippet: Codable, Equatable {
        let text: String
    }
}
