@testable import muterCore
import XCTest

final class TestingTimeoutExecutorTests: MuterTestCase {
    private let sut = TestingTimeoutExecutor()

    func test_timeout() async throws {
        let expect = expectation(description: #function)

        try await sut.withTimeLimit(1) {
            try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
        } timeoutHandler: {
            expect.fulfill()
        }

        await fulfillment(of: [expect], timeout: 5)
    }

    func test_success() async throws {
        let expect = expectation(description: #function)

        try await sut.withTimeLimit(2) {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            expect.fulfill()
        } timeoutHandler: {}

        await fulfillment(of: [expect], timeout: 5)
    }

    // Ctrl-Z suspends the tests with SwiftMutator, so the time suspended doesn't count toward their limit.
    func test_theTimeSuspended_doesntCount() async throws {
        let suspensions = current.suspensions
        suspensions.begin()
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            suspensions.end()
        }

        let outcome: String = try await sut.withTimeLimit(0.2) {
            try await Task.sleep(nanoseconds: 300_000_000)
            return "finished"
        } timeoutHandler: {
            "timed out"
        }

        XCTAssertEqual(outcome, "finished")
    }

    // The limit was cut to whole seconds before it became nanoseconds, so a limit under a second
    // was no limit at all: the time-out fired at once.
    func test_aFractionalTimeLimitKeepsItsFraction() async throws {
        let outcome: String = try await sut.withTimeLimit(0.9) {
            try await Task.sleep(nanoseconds: 100_000_000)
            return "finished"
        } timeoutHandler: {
            "timed out"
        }

        XCTAssertEqual(outcome, "finished")
    }
}
