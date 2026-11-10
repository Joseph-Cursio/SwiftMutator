import Foundation
@testable import muterCore

extension InterruptionsTests {
    struct WorkError: Error {}

    /// Work that runs until its task is cancelled: it opens `started` once `onCancel` is in place, then waits until
    /// `onCancel` has run, and throws CancellationError. Only the handler ends the wait. Work that saw the
    /// cancellation another way, as Task.sleep does, could end before `cancel()` ran the handler, and the handler
    /// would never run: `cancel()` sets the task's cancelled flag before it takes the lock under which it runs the
    /// handlers then in place, and work that ends meanwhile removes its own (Swift 6.2–6.4). Gives up after 10
    /// seconds, so the work ends however the test goes.
    static func waitUntilCancelled(opening started: Gate, onCancel: @escaping @Sendable () -> Void) async throws {
        let resumption = Resumption()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { resumption.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resumption.set(continuation)
                started.open()
            }
        } onCancel: {
            onCancel()
            resumption.resume()
        }
        try Task.checkCancellation()
    }

    /// A continuation that `resume()` resumes, once, whether it was set before or after.
    final class Resumption: @unchecked Sendable { // `continuation` and `resumed` are behind `lock`
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var resumed = false

        func set(_ newContinuation: CheckedContinuation<Void, Never>) {
            let alreadyResumed = lock.withLock { () -> Bool in
                if resumed { return true }
                continuation = newContinuation
                return false
            }
            if alreadyResumed { newContinuation.resume() }
        }

        func resume() {
            let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                resumed = true
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume()
        }
    }

    /// Strings appended from any thread, in order.
    final class Events: @unchecked Sendable { // `list` is behind `lock`
        private let lock = NSLock()
        private var list: [String] = []

        var all: [String] { lock.withLock { list } }

        func append(_ event: String) {
            lock.withLock { list.append(event) }
        }

        func count(of event: String) -> Int {
            all.filter { $0 == event }.count
        }
    }

    /// A clock a test moves, in nanoseconds, read from any thread.
    final class Clock: @unchecked Sendable { // `now` is behind `lock`
        private let lock = NSLock()
        private var now: UInt64 = 1_000_000_000

        var nanoseconds: UInt64 { lock.withLock { now } }

        func advance(by nanoseconds: UInt64) {
            lock.withLock { now += nanoseconds }
        }
    }

    /// Opened from any thread; once open, it stays open.
    final class Gate: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func open() {
            semaphore.signal()
        }

        /// Blocks until the gate is open, at most `timeout` seconds, and returns whether it opened.
        @discardableResult
        func wait(within timeout: TimeInterval = 5) -> Bool {
            guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
            semaphore.signal() // for the next wait
            return true
        }
    }

    /// `Interruptions.run` under way in a task of its own, so that a test can send signals meanwhile. Every work a test
    /// runs ends within seconds, however the test goes.
    final class Running: @unchecked Sendable { // `ended` is written before `finished` opens, and read after
        private let finished = Gate()
        private var ended: Interruptions.Ended<Void>?

        init(_ interruptions: Interruptions, _ work: @escaping @Sendable () async throws -> Void) {
            Task.detached { [self] in
                ended = await interruptions.run(work)
                finished.open()
            }
        }

        /// How the run ended, or nil if it hasn't within `timeout` seconds.
        func wait(within timeout: TimeInterval = 5) -> Interruptions.Ended<Void>? {
            finished.wait(within: timeout) ? ended : nil
        }
    }
}
