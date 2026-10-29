import Foundation
@testable import muterCore

// A test sets it up, then the code under test uses it from one task at a time, so it needs no lock.
final class TestingTimeOutExecutorSpy: TestingTimeoutExecution, @unchecked Sendable {

    private(set) var withTimeLimitCalled = false
    private(set) var timeLimitPassed: TimeInterval = 0

    var shouldSucceed = true
    /// Runs the body, then the timeout handler, and returns the handler's value: the time limit fires
    /// just after the run ended, and its task finishes first.
    var firesAfterBody = false
    func withTimeLimit<T: Sendable>(
        _ timeLimit: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T,
        timeoutHandler: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        withTimeLimitCalled = true
        timeLimitPassed = timeLimit

        if firesAfterBody {
            _ = try await body()
            return try await timeoutHandler()
        }
        return shouldSucceed
            ? try await body()
            : try await timeoutHandler()
    }
}
