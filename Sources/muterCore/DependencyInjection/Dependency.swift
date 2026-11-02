import Foundation

/// A dependency read from `current` each time it is used, so a test's replacement reaches every holder. It keeps a
/// key path, not a closure, so a holder of one can be Sendable.
@propertyWrapper
struct Dependency<T> {
    private let keyPath: KeyPath<World, T> & Sendable
    var wrappedValue: T {
        dependency(keyPath)
    }

    init(_ keyPath: KeyPath<World, T> & Sendable) {
        self.keyPath = keyPath
    }
}
