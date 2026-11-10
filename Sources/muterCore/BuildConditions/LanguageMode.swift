import Foundation
import SwiftIfConfig

/// A Swift language mode, as `-swift-version` takes it, and SwiftPM's `swiftLanguageModes` and Xcode's `SWIFT_VERSION`
/// write it.
enum LanguageMode: Comparable, Sendable {
    case swift4, swift4dot2, swift5, swift6

    /// `4`, `4.0`, `4.2`, `5`, `5.0`, `6` or `6.0`; nil for any other.
    init?(_ written: String) {
        switch written.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) {
        case "4", "4.0": self = .swift4
        case "4.2": self = .swift4dot2
        case "5", "5.0": self = .swift5
        case "6", "6.0": self = .swift6
        default: return nil
        }
    }

    /// The version `swift(…)` compares with in this mode, as a Swift 6 compiler at `compiler` sets it: 4.1.50, 4.2,
    /// 5.10, or the compiler's own version. Nil for another compiler, which may set others.
    func languageVersion(compiler: VersionTuple?) -> VersionTuple? {
        guard let compiler, compiler.components.first == 6 else { return nil }
        switch self {
        case .swift4: return VersionTuple(4, 1, 50)
        case .swift4dot2: return VersionTuple(4, 2)
        case .swift5: return VersionTuple(5, 10)
        case .swift6: return compiler
        }
    }

    /// The language version of a build whose targets have `modes`: theirs if they all have one, and the same one; nil
    /// if any can't be told, or two differ.
    static func languageVersion(of modes: [Self?], compiler: VersionTuple?) -> VersionTuple? {
        guard let first = modes.first, let mode = first, modes.allSatisfy({ $0 == mode }) else { return nil }
        return mode.languageVersion(compiler: compiler)
    }

    /// Whether `flags` set the mode themselves, which SwiftMutator doesn't follow.
    static func isSet(inFlags flags: [String]) -> Bool {
        flags.contains { $0 == "-swift-version" || $0 == "-language-mode" || $0.hasPrefix("-language-mode=") }
    }
}
