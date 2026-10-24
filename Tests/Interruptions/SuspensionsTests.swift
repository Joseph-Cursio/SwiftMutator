@testable import muterCore
import XCTest

/// Time limits and durations count only the time SwiftMutator wasn't suspended in, by Ctrl-Z.
final class SuspensionsTests: XCTestCase {
    func test_theClockStandsStill_whileSuspended() {
        let uptime = Clock(nanoseconds: 1_000)
        let sut = Suspensions(uptime: { uptime.nanoseconds })

        uptime.advance(by: 500)
        XCTAssertEqual(sut.activeNanoseconds, 1_500)
        sut.begin()
        uptime.advance(by: 4_000)
        XCTAssertEqual(sut.activeNanoseconds, 1_500, "it moved while suspended")
        sut.end()
        XCTAssertEqual(sut.activeNanoseconds, 1_500)
        uptime.advance(by: 200)
        XCTAssertEqual(sut.activeNanoseconds, 1_700)

        sut.begin()
        uptime.advance(by: 1_000)
        sut.begin() // a second one under way changes nothing
        sut.end()
        sut.end()
        XCTAssertEqual(sut.activeNanoseconds, 1_700)
        // Within a tick of the clock it counts in.
        XCTAssertEqual(Double(sut.instant.uptimeNanoseconds), 1_700, accuracy: 100)
    }

    // After `fg`, a sleep that ended meanwhile sleeps on for the time left when SwiftMutator was suspended.
    func test_aSleep_ignoresTheTimeSuspended() async throws {
        let sut = Suspensions()
        let start = Date()

        async let slept: Void = sut.sleep(for: 0.2)
        try await Task.sleep(nanoseconds: 50_000_000)
        sut.begin()
        try await Task.sleep(nanoseconds: 400_000_000)
        sut.end()
        try await slept

        // 0.05 s before the suspension, 0.4 s in it, and 0.15 s after it.
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.6)
    }

    func test_aSleep_endsAfterItsTime_withoutASuspension() async throws {
        let start = Date()

        try await Suspensions().sleep(for: 0.1)

        let slept = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(slept, 0.1)
        XCTAssertLessThan(slept, 2)
    }

    // On the test's own clock: on the system's, a slow CI runner began the suspension after the work had run.
    func test_workAfterATime_ignoresTheTimeSuspended() {
        let uptime = Clock(nanoseconds: 1_000_000_000) // not 0, where a look that didn't count from `start` would pass
        let sut = Suspensions(uptime: { uptime.nanoseconds })
        let done = expectation(description: "the work ran")
        let ranAt = Clock(nanoseconds: 0)

        sut.after(0.2, on: .global()) {
            ranAt.advance(by: uptime.nanoseconds)
            done.fulfill()
        }
        uptime.advance(by: 50_000_000)
        sut.begin()
        uptime.advance(by: 400_000_000)
        sut.end()
        // Its looks find 0.05 s gone until the test moves the clock on. The first is due 0.2 s of real time after the
        // work was asked for, within this sleep.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(ranAt.nanoseconds, 0, "it counted the time suspended")
        uptime.advance(by: 150_000_000)

        wait(for: [done], timeout: 5)
        // 0.05 s before the suspension, 0.4 s in it, and 0.15 s after it.
        XCTAssertEqual(ranAt.nanoseconds, 1_600_000_000)
    }
}

/// A clock a test moves, read from any thread.
private final class Clock: @unchecked Sendable { // `now` is behind `lock`
    private let lock = NSLock()
    private var now: UInt64

    init(nanoseconds: UInt64) {
        now = nanoseconds
    }

    var nanoseconds: UInt64 { lock.withLock { now } }

    func advance(by nanoseconds: UInt64) {
        lock.withLock { now += nanoseconds }
    }
}
