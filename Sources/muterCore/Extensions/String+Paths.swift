import Foundation

/// NSString's path operations on String, which has none of its own. They work on the text of the path alone, unlike
/// `URL(fileURLWithPath:)`, which resolves a relative or `~` path against the current directory.
extension String {
    /// The last component of the path, as `NSString.lastPathComponent` gives it.
    var lastPathComponent: String { bridged.lastPathComponent }

    /// The path without its last component, as `NSString.deletingLastPathComponent` gives it.
    var deletingLastPathComponent: String { bridged.deletingLastPathComponent }

    /// The path's extension, without the dot, or an empty string if it has none.
    var pathExtension: String { bridged.pathExtension }

    /// The path without its extension.
    var deletingPathExtension: String { bridged.deletingPathExtension }

    /// The path's components, `/` first for an absolute path.
    var pathComponents: [String] { bridged.pathComponents }

    /// The path with `~` and `~user` expanded.
    var expandingTildeInPath: String { bridged.expandingTildeInPath }

    /// The path with `.`, `..`, extra slashes and a leading `/private` removed, as `NSString.standardizingPath` does.
    var standardizingPath: String { bridged.standardizingPath }

    // swiftlint:disable:next legacy_objc_type - the path methods above are NSString's; String has none
    private var bridged: NSString { self as NSString }

    /// The path with `component` added after a `/`.
    func appendingPathComponent(_ component: String) -> String {
        bridged.appendingPathComponent(component)
    }

    /// The path made of `components`, as `NSString.path(withComponents:)` makes it.
    static func path(withComponents components: [String]) -> String {
        components.isEmpty ? "" : components[0].bridged.appendingPathComponent(
            Self.path(withComponents: Array(components.dropFirst()))
        )
    }
}
