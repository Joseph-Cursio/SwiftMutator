import Foundation

public extension URL {
    /// The path, without `file://`.
    func withoutScheme() -> String {
        String(
            pathComponents
                .joined(separator: "/")
                .dropFirst()
        )
    }
}
