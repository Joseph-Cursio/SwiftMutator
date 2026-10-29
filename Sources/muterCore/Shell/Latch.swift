import Foundation

/// Opens once, from any thread, and lets tasks wait for that without holding a thread, as `waitUntilExit()` or a
/// semaphore would: Swift concurrency has only about as many threads as the machine has cores. Opened by a process's
/// `terminationHandler`, it says the process has exited; by a reader, that it has read its pipe to the end.
final class Latch: @unchecked Sendable { // `isOpen`, `waiters` and `nextWaiter` are behind `lock`
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0

    /// Opens the latch, and resumes every task waiting for it. Opening it again does nothing.
    func open() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !isOpen else { return [] }
            isOpen = true
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        resumed.forEach { $0.resume() }
    }

    /// Whether the latch has opened.
    var hasOpened: Bool { lock.withLock { isOpen } }

    /// How many tasks wait for the latch to open.
    var waiterCount: Int { lock.withLock { waiters.count } }

    /// Returns once the latch opens, at once if it has. Ignores cancellation, as `waitUntilExit()` does: whoever
    /// cancels the wait for a process kills the process, and this returns once it is gone.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if add(continuation) == nil { continuation.resume() }
        }
    }

    /// Returns once the latch opens or `seconds` have passed, whichever is first, and whether it opened. Ignores
    /// cancellation too.
    @discardableResult
    func wait(atMost seconds: TimeInterval) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let waiter = add(continuation) else { return continuation.resume() }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) { [self] in
                lock.withLock { waiters.removeValue(forKey: waiter) }?.resume()
            }
        }
        return hasOpened
    }

    /// Adds `continuation` to those waiting, and returns its key, or nil if the latch has opened.
    private func add(_ continuation: CheckedContinuation<Void, Never>) -> Int? {
        lock.withLock {
            guard !isOpen else { return nil }
            nextWaiter += 1
            waiters[nextWaiter] = continuation
            return nextWaiter
        }
    }
}
