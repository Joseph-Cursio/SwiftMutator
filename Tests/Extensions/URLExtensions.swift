import Foundation

public extension URL {
    func withoutScheme() -> String {
        String(
            pathComponents
                .joined(separator: "/")
                .dropFirst()
        )
    }
}
