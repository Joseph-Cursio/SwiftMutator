@testable import muterCore
import XCTest

extension InterruptionsTests {
    // Ctrl-\ sends SIGQUIT, which reaches SwiftMutator alone. Its default action would leave every test process
    // running, and no end line.
    func test_aSIGQUIT_stopsAtOnce_killingDescendants_andEndingTheResults() throws {
        let exitGate = exited
        endingTheResultsAtOnce()
        let running = Running(makeInterruptions()) { exitGate.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGQUIT))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(Array(events.all.prefix(3)), ["killed", "ended the results", "exited by SIGQUIT"])
        XCTAssertEqual(ended.signal, SIGQUIT)
        XCTAssertEqual(said.all.count, 1)
        XCTAssertEqual(said.all.first?.hasPrefix("⏹ Stopping at once."), true, "\(said.all)")
    }

    // A worker not cancelled would start its next mutant's tests as soon as this one's are killed: nothing would kill
    // them once SwiftMutator had exited.
    func test_aSIGQUIT_cancelsTheWork_beforeKillingDescendants() throws {
        let started = Gate()
        let eventLog = events
        let running = Running(makeInterruptions()) {
            try await Self.waitUntilCancelled(opening: started) { eventLog.append("cancelled") }
        }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGQUIT))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(Array(eventLog.all.prefix(3)), ["cancelled", "killed", "exited by SIGQUIT"])
    }

    func test_aSIGQUIT_whileStopping_exitsByTheFirstSignal() throws {
        let exitGate = exited
        let running = Running(makeInterruptions()) { exitGate.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGHUP))
        XCTAssertTrue(observer.send(SIGQUIT))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(Array(events.all.prefix(3)), ["killed", "killed", "exited by SIGHUP"])
        XCTAssertEqual(ended.signal, SIGHUP)
    }

    // Once the work has ended, as when the results file is already closed, there's nothing to end.
    func test_withNothingToEnd_stoppingAtOnceStillExits() throws {
        let exitGate = exited
        current.interruption.beforeStoppingAtOnce(nil)
        let running = Running(makeInterruptions()) { exitGate.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGQUIT))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(Array(events.all.prefix(2)), ["killed", "exited by SIGQUIT"])
    }
}
