import Foundation

/// Keeps a Mac left alone from going to sleep and leaving a run that makes no progress until someone wakes it, on
/// battery too. The display can still sleep, and closing the lid still sleeps the Mac. If SwiftMutator dies without
/// ending it, as from a SIGKILL or a crash, the system ends it with the process. On other systems it does nothing.
final class IdleSleepPrevention: @unchecked Sendable { // `release` is behind `lock`
    /// What `pmset -g assertions` shows beside the process.
    static let reason = "SwiftMutator is running mutation tests"

    private let lock = NSLock()
    private let hold: @Sendable () -> @Sendable () -> Void
    private var release: (@Sendable () -> Void)?

    /// `hold` stops idle sleep, and returns what lets it happen again.
    init(hold: @escaping @Sendable () -> @Sendable () -> Void = { IdleSleepPrevention.holdOnThisSystem() }) {
        self.hold = hold
    }

    /// Stops idle sleep, unless this has already.
    func begin() {
        lock.withLock {
            if release == nil { release = hold() }
        }
    }

    /// Lets idle sleep happen again, unless it can already.
    func end() {
        lock.withLock {
            release?()
            release = nil
        }
    }

    private static func holdOnThisSystem() -> @Sendable () -> Void {
        #if os(macOS)
        // Not the assertion `caffeinate -s` makes, which the man page says is valid only on AC power.
        nonisolated(unsafe) let activity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: reason
        )
        return { ProcessInfo.processInfo.endActivity(activity) }
        #else
        return {}
        #endif
    }
}
