@testable import muterCore
import XCTest

final class TestRunEndingTests: XCTestCase {
    func test_theFirstReasonIsKept() {
        let ending = TestRunEnding()

        XCTAssertTrue(ending.record(.timedOut))
        XCTAssertFalse(ending.record(.exited))
        XCTAssertFalse(ending.record(.cancelled))
        XCTAssertEqual(ending.reason, .timedOut)
    }

    // A time limit or a cancellation that comes after the exit may not kill the process: the system
    // may have given its ID to another process.
    func test_recordingTheExit_stopsAnyKill() {
        let ending = TestRunEnding()

        XCTAssertTrue(ending.record(.exited))
        XCTAssertFalse(ending.record(.timedOut))
        XCTAssertFalse(ending.record(.cancelled))
        XCTAssertEqual(ending.reason, .exited)
    }

    // Whatever waits for the latch then finds the run ended by its exit, so neither the follower nor the time limit,
    // which act on what is recorded, kills a process that has exited.
    func test_theTerminationHandler_recordsTheExit_andOpensTheLatch() {
        let ending = TestRunEnding()
        let exited = Latch()

        ending.recordingExit(opening: exited)(Foundation.Process())

        XCTAssertEqual(ending.reason, .exited)
        XCTAssertTrue(exited.hasOpened)
    }

    // A run its time limit ended still lets its waiter go once the killed process exits.
    func test_theTerminationHandler_afterTheTimeLimit_keepsTheTimeout_andOpensTheLatch() {
        let ending = TestRunEnding()
        let exited = Latch()
        XCTAssertTrue(ending.record(.timedOut))

        ending.recordingExit(opening: exited)(Foundation.Process())

        XCTAssertEqual(ending.reason, .timedOut)
        XCTAssertTrue(exited.hasOpened)
    }

    func test_concurrentRecords_haveOneWinner() {
        let ending = TestRunEnding()
        let reasons: [TestRunEnding.Reason] = [.exited, .timedOut, .cancelled, .failedTest(line: "✘ Test a() …")]
        let lock = NSLock()
        var winners: [TestRunEnding.Reason] = []

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let reason = reasons[index % reasons.count]
            if ending.record(reason) {
                lock.withLock { winners.append(reason) }
            }
        }

        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(ending.reason, winners.first)
    }

    func test_executionResult_followsTheReason() throws {
        XCTAssertEqual(try ending(.exited).executionResult(), .success)
        XCTAssertEqual(try ending(.timedOut).executionResult(), .timeout)
        XCTAssertEqual(try ending(.failedTest(line: "✘ Test a() …")).executionResult(), .stoppedAtFirstFailure)
        XCTAssertThrowsError(try ending(.cancelled).executionResult()) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    private func ending(_ reason: TestRunEnding.Reason) -> TestRunEnding {
        let ending = TestRunEnding()
        _ = ending.record(reason)
        return ending
    }
}
