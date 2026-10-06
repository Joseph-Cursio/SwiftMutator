import Foundation
@testable import muterCore

/// Stands in for `DispatchSignalObserver`, so that a test never signals the test runner: `send(_:)` delivers a signal
/// to the handler, on the queue `start` was given, as a signal source would.
final class SignalObserverFake: SignalObserving, @unchecked Sendable { // `observing` and `didStop` are behind `lock`
    private struct Observing {
        let signals: [Int32]
        let queue: DispatchQueue
        let handler: (Int32) -> Void
    }

    /// The signals taken to be ignored (SIG_IGN) when SwiftMutator started, which `start` leaves alone.
    let ignoredAtStart: Set<Int32>
    private let lock = NSLock()
    private var observing: Observing?
    private var didStop = false

    init(ignoredAtStart: Set<Int32> = []) {
        self.ignoredAtStart = ignoredAtStart
    }

    /// The signals `start` observes: none before it is called.
    var observed: [Int32] { lock.withLock { observing?.signals ?? [] } }
    var stopped: Bool { lock.withLock { didStop } }

    @discardableResult
    func start(observing signals: [Int32], on queue: DispatchQueue, handler: @escaping (Int32) -> Void) -> [Int32] {
        let observed = signals.filter { !ignoredAtStart.contains($0) }
        lock.withLock {
            observing = Observing(signals: observed, queue: queue, handler: handler)
            didStop = false
        }
        return observed
    }

    func stop() {
        lock.withLock { didStop = true }
    }

    /// Delivers `signal` to the handler on its queue, if it is observed and `stop()` hasn't been called, and returns
    /// once the handler has. Returns whether the handler ran. Call it off that queue.
    @discardableResult
    func send(_ signal: Int32) -> Bool {
        guard let queue = lock.withLock({ observing?.queue }) else { return false }
        return queue.sync {
            let handler = lock.withLock { () -> ((Int32) -> Void)? in
                guard let observing, !didStop, observing.signals.contains(signal) else { return nil }
                return observing.handler
            }
            handler?(signal)
            return handler != nil
        }
    }
}
