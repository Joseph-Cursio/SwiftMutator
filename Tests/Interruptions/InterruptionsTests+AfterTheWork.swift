@testable import muterCore
import XCTest

extension InterruptionsTests {
    // MARK: - After the work ends

    func test_withoutASignal_whatIsSetForAfterTheWork_runsOnce_afterIt() throws {
        let eventLog = events
        current.interruption.afterWorkEnds { eventLog.append("after the work") }
        let running = Running(makeInterruptions()) { eventLog.append("work ended") }

        _ = try XCTUnwrap(running.wait())
        let record = current.interruption
        let again = Gate()
        Task { await record.workEnded(); again.open() }
        XCTAssertTrue(again.wait())

        XCTAssertEqual(eventLog.all, ["work ended", "after the work"])
    }

    // What it does starts processes, as `simctl delete`, which a kill of the descendants would kill.
    func test_afterAFirstSignal_whatIsSetForAfterTheWork_runsAfterTheLastKill_withNoMoreKillsMeanwhile() throws {
        let eventLog = events
        current.interruption.afterWorkEnds {
            eventLog.append("removing")
            try? await Task.sleep(nanoseconds: 100_000_000)
            eventLog.append("removed")
        }
        let started = Gate()
        let running = Running(makeInterruptions(sweepInterval: 0.01)) {
            try await Self.waitUntilCancelled(opening: started) { eventLog.append("cancelled") }
        }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGINT))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(ended.signal, SIGINT)
        XCTAssertEqual(eventLog.all.suffix(3), ["killed", "removing", "removed"])
        XCTAssertFalse(observer.stopped, "a second signal must still stop SwiftMutator at once")
    }

    // SwiftMutator ends at once, and its next run's sweep deletes the simulators.
    func test_stoppingAtOnce_neverRunsWhatIsSetForAfterTheWork() throws {
        let eventLog = events
        let exitGate = exited
        current.interruption.afterWorkEnds { eventLog.append("after the work") }
        let running = Running(makeInterruptions()) { exitGate.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGQUIT))
        _ = try XCTUnwrap(running.wait())

        // The stand-in for exiting returns, so the work ends, and is followed by the last kill.
        XCTAssertEqual(Array(eventLog.all.prefix(2)), ["killed", "exited by SIGQUIT"])
        XCTAssertFalse(eventLog.all.contains("after the work"), "\(eventLog.all)")
    }

    // `nohup` ignores SIGHUP, so that a run outlives its terminal.
    func test_aSignalIgnoredAtStart_neverStopsTheWork() throws {
        observer = SignalObserverFake(ignoredAtStart: [SIGHUP])
        let finish = Gate()
        let running = Running(makeInterruptions()) { finish.wait() }
        waitUntilObserving()

        XCTAssertFalse(observer.send(SIGHUP))
        finish.open()
        let ended = try XCTUnwrap(running.wait())

        XCTAssertNil(ended.signal)
        XCTAssertEqual(observer.observed, [SIGINT, SIGTERM, SIGQUIT, SIGTSTP])
        XCTAssertEqual(events.all, [])
        XCTAssertEqual(said.all, [])
    }
}
