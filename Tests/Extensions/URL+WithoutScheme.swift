import Foundation

public extension URL {
    /// The URL's path rebuilt from its path components, without the scheme.
    func withoutScheme() -> String {
        String(
            pathComponents
                .joined(separator: "/")
                .dropFirst()
        )
    }
}
