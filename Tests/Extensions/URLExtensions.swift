import Foundation

public extension URL {
    func withoutScheme() -> String {
        return String(
            pathComponents
                .joined(separator: "/")
                .dropFirst()
        )
    }
}
