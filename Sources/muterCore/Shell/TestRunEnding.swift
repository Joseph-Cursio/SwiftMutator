import Foundation

/// Why a test run ended. Several things can end one at almost the same time: its process exiting, its
/// time limit, its first failed test, its task being cancelled. Only the first is recorded, so only that
/// one kills the process, and the outcome follows it. Recording the exit closes it, so nothing kills a
/// process that has exited, whose ID the system may give to another process.
final class TestRunEnding: @unchecked Sendable { // all state is behind `lock`
    enum Reason: Equatable {
        case exited
        case timedOut
        case cancelled
        /// Its first failed test (`stopAtFirstFailure`); `line` is the log line that shows it.
        case failedTest(line: String)
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

    /// A `terminationHandler` that records the exit, then opens `exited`: whatever waits for the latch finds the run
    /// ended by its exit, and nothing kills the process after. Set it before `run()`, as a process can exit before
    /// `run()` returns.
    func recordingExit(opening exited: Latch) -> @Sendable (Foundation.Process) -> Void {
        { [self] _ in
            _ = record(.exited)
            exited.open()
        }
    }

    /// Records that `process` ran past its time limit, and returns whether it did, for the caller to kill it. A process
    /// that has exited, though Foundation hasn't yet said so, is recorded as exited instead: when SwiftMutator was
    /// stopped, as by a SIGSTOP, while its tests ran on, its time limit and its exit come together once it continues.
    func recordTimeLimit(of process: MuterProcess) -> Bool {
        guard !process.hasExited() else {
            _ = record(.exited)
            return false
        }
        return record(.timedOut)
    }

    /// Why the run ended, or nil if nothing has ended it yet.
    var reason: Reason? { lock.withLock { recorded } }

    /// How the run ended, for `TestSuiteOutcome.from`. A cancelled run has no outcome.
    func executionResult() throws -> TestingExecutionResult {
        switch reason {
        case .failedTest: return .stoppedAtFirstFailure
        case .timedOut: return .timeout
        case .cancelled: throw CancellationError()
        case .exited, nil: return .success
        }
    }
}
