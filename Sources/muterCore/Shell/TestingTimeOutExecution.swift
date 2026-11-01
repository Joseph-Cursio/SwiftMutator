import Foundation

protocol TestingTimeoutExecution {
    /// Runs `body`, and `timeoutHandler` once `timeLimit` seconds have passed, and returns what the first of them to
    /// end returns. Each runs in a task of its own, so what it returns must be Sendable.
    func withTimeLimit<T: Sendable>(
        _ timeLimit: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T,
        timeoutHandler: @escaping @Sendable () async throws -> T
    ) async throws -> T
}

enum TestingExecutionResult {
    case success
    case timeout
    /// Stopped at its first failed test (`stopAtFirstFailure`).
    case stoppedAtFirstFailure
    /// Stopped at a test process's crash, before any failed test (`stopAtFirstFailure`).
    case stoppedAtCrash
}

/// A time limit counts only the time SwiftMutator wasn't suspended in, by Ctrl-Z: its test processes are suspended
/// with it.
struct TestingTimeoutExecutor: TestingTimeoutExecution {
    @Dependency(\.suspensions)
    private var suspensions: Suspensions

    func withTimeLimit<T: Sendable>(
        _ timeLimit: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T,
        timeoutHandler: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let suspensions = suspensions
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer {
                group.cancelAll()
            }

            group.addTask {
                // If sleep() returns instead of throwing a CancellationError, that means
                // the timeout was reached before this task could be cancelled, so call
                // the timeout handler.
                try await suspensions.sleep(for: timeLimit)
                return try await timeoutHandler()
            }

            group.addTask(operation: body)

            guard let result = try await group.next() else {
                throw CancellationError()
            }

            return result
        }
    }
}
