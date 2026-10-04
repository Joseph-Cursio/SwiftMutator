import Foundation

/// Why a test run ended. Several things can end one at almost the same time: its process exiting, its
/// time limit, its task being cancelled. Only the first is recorded, so only that one kills the process,
/// and the outcome follows it. Recording the exit closes it, so nothing kills a process that has exited,
/// whose ID the system may give to another process.
final class TestRunEnding: @unchecked Sendable { // all state is behind `lock`
    enum Reason: Equatable {
        case exited
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var recorded: Reason?

    /// Records `reason` unless the run already ended for another, and returns whether it did.
    func record(_ reason: Reason) -> Bool {
        lock.withLock {
            guard recorded == nil else { return false }
            recorded = reason
            return true
        }
    }

    /// Why the run ended, or nil if nothing has ended it yet.
    var reason: Reason? { lock.withLock { recorded } }

    /// How the run ended, for `TestSuiteOutcome.from`. A cancelled run has no outcome.
    func executionResult() throws -> TestingExecutionResult {
        switch reason {
        case .timedOut: return .timeout
        case .cancelled: throw CancellationError()
        case .exited, nil: return .success
        }
    }
}
