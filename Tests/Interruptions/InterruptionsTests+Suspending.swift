@testable import muterCore
import XCTest

extension InterruptionsTests {
    // Ctrl-Z reaches SwiftMutator alone: its test processes lead process groups of their own. They are suspended with
    // it, and no time limit counts the time.
    func test_aSIGTSTP_suspendsSwiftMutatorWithItsDescendants_withoutCountingTheTime() throws {
        let uptime = Clock()
        current.suspensions = Suspensions { uptime.nanoseconds }
        let finish = Gate()
        let running = Running(makeInterruptions { [events] in
            events.append("suspended")
            uptime.advance(by: 5_000_000_000)
        }) { finish.wait() }
        waitUntilObserving()
        let before = current.suspensions.activeNanoseconds

        XCTAssertTrue(observer.send(SIGTSTP))
        finish.open()
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(events.all, ["suspended"])
        XCTAssertEqual(current.suspensions.activeNanoseconds, before, "the time suspended counted")
        XCTAssertNil(ended.signal)
        XCTAssertNoThrow(try ended.result.get())
        XCTAssertEqual(said.all, [])
        XCTAssertTrue(observer.stopped)
    }

    // It is about to end, and the grace period would count the time.
    func test_aSIGTSTP_whileStopping_isIgnored() throws {
        let running = Running(makeInterruptions { [events] in events.append("suspended") }) {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGINT))
        XCTAssertTrue(observer.send(SIGTSTP))
        _ = try XCTUnwrap(running.wait())

        XCTAssertFalse(events.all.contains("suspended"), "\(events.all)")
    }
}
