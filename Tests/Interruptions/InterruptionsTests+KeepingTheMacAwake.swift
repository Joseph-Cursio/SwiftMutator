@testable import muterCore
import XCTest

extension InterruptionsTests {
    // MARK: - Keeping the Mac awake

    func test_theMacStaysAwake_whileTheWorkRuns_andNotOnceItHasFinished() async {
        let idleSleepLog = idleSleep

        let during = await makeInterruptions().run { idleSleepLog.all }

        XCTAssertEqual(try during.result.get(), ["held"])
        XCTAssertEqual(idleSleepLog.all, ["held", "released"])
    }

    func test_theMacCanSleep_onceTheWorkHasThrown() async {
        let ended = await makeInterruptions().run { throw WorkError() }

        XCTAssertThrowsError(try ended.result.get())
        XCTAssertEqual(idleSleep.all, ["held", "released"])
    }

    // By the time the caller exits by the signal.
    func test_theMacCanSleep_onceASignalHasStoppedTheWork() throws {
        let started = Gate()
        let running = Running(makeInterruptions()) { try await Self.waitUntilCancelled(opening: started) {} }
        XCTAssertTrue(started.wait())
        waitUntilObserving()
        XCTAssertEqual(idleSleep.all, ["held"])

        XCTAssertTrue(observer.send(SIGTERM))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(ended.signal, SIGTERM)
        XCTAssertEqual(idleSleep.all, ["held", "released"])
    }

    // SwiftMutator ends with the work still running, so `run` never gets to end it.
    func test_stoppingAtOnce_letsTheMacSleep_beforeExiting() throws {
        let exitGate = exited
        let idleSleepLog = idleSleep
        let atExit = Events()
        let onExit: @Sendable () -> Void = { atExit.append(idleSleepLog.all.joined(separator: " ")) }
        let running = Running(makeInterruptions(onExit: onExit)) {
            exitGate.wait()
        }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGQUIT))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(atExit.all, ["held released"])
    }

    // A run left suspended shouldn't keep a Mac awake for days.
    func test_theMacCanSleep_whileSuspended_andStaysAwakeOnceContinued() throws {
        let finish = Gate()
        let idleSleepLog = idleSleep
        let whileSuspended = Events()
        let interruptions = makeInterruptions { whileSuspended.append(idleSleepLog.all.joined(separator: " ")) }
        let running = Running(interruptions) { finish.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGTSTP))
        XCTAssertTrue(Self.waitUntil(within: 5) { idleSleepLog.all.count == 3 }, "\(idleSleepLog.all)")
        XCTAssertEqual(idleSleepLog.all, ["held", "released", "held"], "still running, so it is held again")
        finish.open()
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(whileSuspended.all, ["held released"])
        XCTAssertEqual(idleSleepLog.all, ["held", "released", "held", "released"])
    }

    // It is about to end, so it stays held until it does.
    func test_aSIGTSTP_whileStopping_keepsTheMacAwakeUntilTheWorkEnds() throws {
        let started = Gate()
        let running = Running(makeInterruptions()) { try await Self.waitUntilCancelled(opening: started) {} }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGINT))
        XCTAssertTrue(observer.send(SIGTSTP))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(idleSleep.all, ["held", "released"])
    }
}
