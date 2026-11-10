import Foundation

enum BuildSystem: String, Codable, Equatable {
    case xcodebuild
    case swift
    case unknown

    init(rawValue: String) {
        switch rawValue {
        case "swift": self = .swift
        case "xcodebuild": self = .xcodebuild
        default: self = .unknown
        }
    }

    /// The build system `written` names exactly, `swift` or `xcodebuild`, or nil.
    init?(written: String) {
        switch written {
        case "swift": self = .swift
        case "xcodebuild": self = .xcodebuild
        default: return nil
        }
    }

    /// What a written `buildSystem:` means where an earlier version may have written it, in a results file's header
    /// or a baseline file: `unknown` is what it wrote for any other value, which it then ignored, going by
    /// `executable`'s name, as for no value. So it is read as no value, and compares equal to a configuration that
    /// leaves the key out, which then resumes that run.
    static let recordedUnknown = "unknown"

    static func coverage(
        for buildSystem: Self
    ) -> BuildSystemCoverage? {
        switch buildSystem {
        case .swift: return SwiftCoverage()
        case .xcodebuild: return XcodeBuildCoverage()
        default: return nil
        }
    }
}
