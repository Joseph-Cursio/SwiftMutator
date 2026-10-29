@testable import muterCore
import XCTest

/// Every wait is bounded, so a latch that never lets a waiter go fails a test rather than hanging the suite.
final class LatchTests: XCTestCase {
    // A process can exit, and its terminationHandler open the latch, before anything waits for it.
    func test_waitingForAnOpenLatch_returnsAtOnce() async {
        let latch = Latch()
        latch.open()

        let ended = await waitsEnd(for: latch)

        XCTAssertTrue(ended)
    }

    // Fewer waiters than Swift concurrency has threads, so a latch that held one per waiter fails the test rather than
    // hanging it: `test_waiters_holdNoThread` checks that.
    func test_opening_resumesEveryWaiter() async {
        let latch = Latch()
        let waiters = 3
        let resumed = expectation(description: "every waiter resumed")
        resumed.expectedFulfillmentCount = waiters
        for _ in 0..<waiters {
            Task {
                await latch.wait()
                resumed.fulfill()
            }
        }
        await waitUntil(latch, has: waiters)

        latch.open()

        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(latch.waiterCount, 0)
    }

    func test_openingTwice_isHarmless() async {
        let latch = Latch()

        latch.open()
        latch.open()
        let ended = await waitsEnd(for: latch)

        XCTAssertTrue(ended)
    }

    func test_aLatchOpenedFromAnotherThread_resumesItsWaiter() async {
        let latch = Latch()
        let resumed = expectation(description: "the waiter resumed")
        Task {
            await latch.wait()
            resumed.fulfill()
        }
        await waitUntil(latch, has: 1)

        Thread.detachNewThread { latch.open() }

        await fulfillment(of: [resumed], timeout: 5)
    }

    func test_aTimedWaitForALatchThatNeverOpens_endsAtItsLimit() async {
        let latch = Latch()
        let started = Date()

        let opened = await latch.wait(atMost: 0.1)

        XCTAssertFalse(opened)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.1)
        XCTAssertEqual(latch.waiterCount, 0, "the waiter is let go")
    }

    func test_aTimedWait_endsWhenTheLatchOpens() async {
        let latch = Latch()
        let started = Date()
        let opened = expectation(description: "the timed wait ended")
        Task {
            let didOpen = await latch.wait(atMost: 10)
            XCTAssertTrue(didOpen)
            opened.fulfill()
        }
        await waitUntil(latch, has: 1)

        latch.open()

        await fulfillment(of: [opened], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // A timed wait that ran out leaves nothing behind for `open()` to resume a second time.
    func test_openingALatchAfterATimedWaitRanOut_isHarmless() async {
        let latch = Latch()

        await latch.wait(atMost: 0.01)
        latch.open()
        let ended = await waitsEnd(for: latch)

        XCTAssertTrue(ended)
    }

    // Waiting holds no thread: with far more waiters than Swift concurrency has threads, a task started after them
    // still runs. Synchronous, so the test itself doesn't need one of those threads, and a latch that held them
    // fails it rather than hanging it.
    func test_waiters_holdNoThread() {
        let latch = Latch()
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 4
        let resumed = expectation(description: "every waiter resumed")
        resumed.expectedFulfillmentCount = waiters
        for _ in 0..<waiters {
            Task {
                await latch.wait()
                resumed.fulfill()
            }
        }

        let probe = expectation(description: "a task started after the waiters ran")
        Task { probe.fulfill() }
        wait(for: [probe], timeout: 5)

        latch.open()
        wait(for: [resumed], timeout: 5)
    }

    // MARK: - Helpers

    /// Whether a wait for `latch`, in a task of its own, ends within `timeout` seconds.
    private func waitsEnd(for latch: Latch, within timeout: TimeInterval = 5) async -> Bool {
        let ended = expectation(description: "the wait ended")
        Task {
            await latch.wait()
            ended.fulfill()
        }
        return await XCTWaiter().fulfillment(of: [ended], timeout: timeout) == .completed
    }

    /// Returns once `count` tasks wait for `latch`, or fails after 5 seconds, so a test opens it with its waiters
    /// waiting rather than before they start.
    private func waitUntil(_ latch: Latch, has count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while latch.waiterCount < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(latch.waiterCount, count, "the waiters didn't all start waiting")
    }
}
