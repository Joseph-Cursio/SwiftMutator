import Foundation

/// The time SwiftMutator spends suspended, by Ctrl-Z, until `fg` or `bg` continues it. Its test processes are
/// suspended with it, so no time limit counts that time, and no duration includes it.
final class Suspensions: @unchecked Sendable { // `total` and `since` are behind `lock`
    private let lock = NSLock()
    /// Nanoseconds suspended, not counting a suspension under way.
    private var total: UInt64 = 0
    /// When the suspension under way began, if there is one.
    private var since: UInt64?
    private let uptime: @Sendable () -> UInt64

    /// `uptime` is the monotonic clock, in nanoseconds.
    init(uptime: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.uptime = uptime
    }

    /// The monotonic clock, in nanoseconds, less every suspension: it stands still while SwiftMutator is suspended.
    var activeNanoseconds: UInt64 {
        lock.withLock { (since ?? uptime()) - total }
    }

    /// `activeNanoseconds` as a `DispatchTime`, for `World.instant`.
    var instant: DispatchTime { DispatchTime(uptimeNanoseconds: activeNanoseconds) }

    /// Called just before SwiftMutator suspends its test processes and itself.
    func begin() {
        lock.withLock {
            if since == nil { since = uptime() }
        }
    }

    /// Called once SwiftMutator has continued, and has continued its test processes.
    func end() {
        lock.withLock {
            guard let start = since else { return }
            total += uptime() - start
            since = nil
        }
    }

    /// Returns once `seconds` have passed that SwiftMutator wasn't suspended in. Throws a CancellationError if the
    /// task is cancelled first.
    func sleep(for seconds: TimeInterval) async throws {
        let start = activeNanoseconds
        let limit = Self.nanoseconds(seconds)
        while true {
            // A sleep that ends while SwiftMutator is suspended, or once it continues, finds the clock stood still.
            let elapsed = activeNanoseconds - start
            guard elapsed < limit else { return }
            try await Task.sleep(nanoseconds: limit - elapsed)
        }
    }

    /// Runs `work` on `queue` once `seconds` have passed that SwiftMutator wasn't suspended in.
    func after(_ seconds: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        let start = activeNanoseconds
        let limit = Self.nanoseconds(seconds)
        @Sendable func check() {
            let elapsed = activeNanoseconds - start
            guard elapsed < limit else { return work() }
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(limit - elapsed)), execute: check)
        }
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(limit)), execute: check)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(seconds, 0) * 1_000_000_000)
    }
}
