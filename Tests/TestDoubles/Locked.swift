import Foundation

/// A value a test shares with the closures it gives SwiftMutator's dependencies, which are `@Sendable`, as the code
/// under test may call them from any thread. It changes only through `change`, so `+=` and `append` can't lose a
/// change made between their read and their write.
final class Locked<Value>: @unchecked Sendable { // `stored` is behind `lock`
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    /// Changes the value in place, and returns what `change` returns.
    @discardableResult
    func change<Result>(_ change: (inout Value) -> Result) -> Result {
        lock.withLock { change(&stored) }
    }
}
