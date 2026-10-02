import Foundation

/// The access level, if any, that a module states on its imports of Foundation.
///
/// One module's imports of Foundation must agree on whether they state an access level. Measured
/// with swift 6.3.3 in Swift 5 and 6 language modes: `import Foundation` in one file and
/// `internal import class Foundation.ProcessInfo` in another fails, and so does the reverse
/// ("ambiguous implicit access level for import of 'Foundation'"). A `public import` mixes with
/// either. So the `ProcessInfo` import SwiftMutator injects has to copy the module's own level:
/// `nil` (a plain import) unless the module imports Foundation as `internal` or narrower.
enum FoundationImportStyle {
    private static let lock = NSLock()
    // Discovery prepares files concurrently, and every file in a module would otherwise rescan it.
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    private static let explicitImport = try! NSRegularExpression(
        pattern: #"^[ \t]*(internal|package|fileprivate|private)[ \t]+import[ \t]+"#
            + #"(?:(?:class|struct|enum|protocol|func|var|let|typealias)[ \t]+)?Foundation(?:\.\w+)?[ \t]*(?://.*)?$"#,
        options: .anchorsMatchLines
    )

    static func accessLevel(forFileAt path: String) -> String? {
        let module = moduleDirectory(of: path)
        lock.lock()
        if let cached = cache[module] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let level = scan(module)

        lock.lock()
        cache[module] = .some(level)
        lock.unlock()
        return level
    }

    /// `…/Sources/<Target>` for a SwiftPM layout, otherwise the file's own folder.
    static func moduleDirectory(of path: String) -> String {
        let components = (path as NSString).pathComponents
        if let index = components.lastIndex(of: "Sources"), index + 1 < components.count - 1 {
            return NSString.path(withComponents: Array(components[...(index + 1)]))
        }
        return (path as NSString).deletingLastPathComponent
    }

    private static func scan(_ module: String) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: module) else {
            return nil
        }
        for case let relative as String in enumerator {
            guard relative.hasSuffix(".swift"),
                  !(relative as NSString).pathComponents.contains(where: { $0.hasPrefix(".build") }),
                  let text = try? String(contentsOfFile: (module as NSString).appendingPathComponent(relative), encoding: .utf8)
            else {
                continue
            }
            let range = NSRange(text.startIndex..., in: text)
            if let match = explicitImport.firstMatch(in: text, range: range),
               let level = Range(match.range(at: 1), in: text) {
                return String(text[level])
            }
        }
        return nil
    }
}
