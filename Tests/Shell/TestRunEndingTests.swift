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

    // As the kernel reports it, before Foundation reaps the process, which on Linux can be long after.
    func test_anExitTheKernelReports_isRecorded_opensTheLatch_andGivesTheStatus() {
        let ending = TestRunEnding()
        let exited = Latch()
        let process = ProcessSpy()
        process.terminationStatus = 0

        ending.recordExit(ProcessExit(status: SIGKILL, reason: .uncaughtSignal), opening: exited)

        XCTAssertEqual(ending.reason, .exited)
        XCTAssertTrue(exited.hasOpened)
        XCTAssertEqual(ending.exit(of: process), ProcessExit(status: SIGKILL, reason: .uncaughtSignal))
    }

    func test_anExitTheKernelReports_afterTheTimeLimit_keepsTheTimeout() {
        let ending = TestRunEnding()
        let exited = Latch()
        XCTAssertTrue(ending.record(.timedOut))

        ending.recordExit(ProcessExit(status: SIGKILL, reason: .uncaughtSignal), opening: exited)

        XCTAssertEqual(ending.reason, .timedOut)
        XCTAssertTrue(exited.hasOpened)
    }

    // Foundation has reaped the process, so its status can be read.
    func test_withNoExitTheKernelReported_theStatusIsFoundations() {
        let ending = TestRunEnding()
        let process = ProcessSpy()
        process.terminationStatus = 3

        ending.recordingExit(opening: Latch())(Foundation.Process())

        XCTAssertEqual(ending.exit(of: process), ProcessExit(status: 3, reason: .exit))
    }

    func test_concurrentRecords_haveOneWinner() {
        let ending = TestRunEnding()
        let reasons: [TestRunEnding.Reason] = [.exited, .timedOut, .cancelled, .failedTest(line: "✘ Test a() …")]
        let winners = Locked<[TestRunEnding.Reason]>([])

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let reason = reasons[index % reasons.count]
            if ending.record(reason) {
                winners.change { $0.append(reason) }
            }
        }

        XCTAssertEqual(winners.value.count, 1)
        XCTAssertEqual(ending.reason, winners.value.first)
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
