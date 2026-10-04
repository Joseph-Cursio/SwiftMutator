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

    func test_concurrentRecords_haveOneWinner() {
        let ending = TestRunEnding()
        let reasons: [TestRunEnding.Reason] = [.exited, .timedOut, .cancelled]
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
