@testable import muterCore
import XCTest

final class LatchTests: XCTestCase {
    // A process can exit, and its terminationHandler open the latch, before anything waits for it.
    func test_waitingForAnOpenLatch_returnsAtOnce() async {
        let latch = Latch()
        latch.open()

        await latch.wait()

        XCTAssertTrue(latch.hasOpened)
    }

    func test_opening_resumesEveryWaiter() async {
        let latch = Latch()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { await latch.wait() }
            }
            latch.open()
        }

        XCTAssertTrue(latch.hasOpened)
    }

    func test_openingTwice_isHarmless() async {
        let latch = Latch()

        latch.open()
        latch.open()
        await latch.wait()

        XCTAssertTrue(latch.hasOpened)
    }

    func test_aLatchOpenedFromAnotherThread_resumesItsWaiter() async {
        let latch = Latch()

        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            latch.open()
        }
        await latch.wait()

        XCTAssertTrue(latch.hasOpened)
    }

    func test_aTimedWaitForALatchThatNeverOpens_endsAtItsLimit() async {
        let latch = Latch()
        let started = Date()

        let opened = await latch.wait(atMost: 0.1)

        XCTAssertFalse(opened)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.1)
    }

    func test_aTimedWait_endsWhenTheLatchOpens() async {
        let latch = Latch()
        let started = Date()

        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.05)
            latch.open()
        }
        let opened = await latch.wait(atMost: 10)

        XCTAssertTrue(opened)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // A timed wait that ran out leaves nothing behind for `open()` to resume a second time.
    func test_openingALatchAfterATimedWaitRanOut_isHarmless() async {
        let latch = Latch()

        await latch.wait(atMost: 0.01)
        latch.open()
        await latch.wait()

        XCTAssertTrue(latch.hasOpened)
    }

    // Waiting holds no thread: with far more waiters than Swift concurrency has threads, a task started after them
    // still runs.
    func test_waiters_holdNoThread() async {
        let latch = Latch()
        let waiters = ProcessInfo.processInfo.activeProcessorCount * 4

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<waiters {
                group.addTask { await latch.wait() }
            }
            let probe = expectation(description: "a task started after the waiters ran")
            Task { probe.fulfill() }
            await fulfillment(of: [probe], timeout: 5)
            latch.open()
        }
    }
}
