@testable import muterCore
import XCTest

/// When the line that names the mutants under way is due: once none has finished for a minute, then each minute while
/// none does.
final class HeartbeatTests: XCTestCase {
    func test_aLineIsDue_aMinuteAfterTheMutantsStart_namingEachWorkersMutant() {
        let sut = heartbeat(workers: 2, startingAt: at(10))
        sut.started("Walker.swift:10:3", on: 1, at: at(20))
        sut.started("Rules.swift:42:17", on: 0, at: at(10))

        XCTAssertEqual(sut.secondsUntilDue(at: at(30)), 40)
        XCTAssertNil(sut.due(at: at(69)))
        XCTAssertEqual(sut.due(at: at(70)), StillTesting(
            runs: [
                .init(worker: 0, place: "Rules.swift:42:17", seconds: 60),
                .init(worker: 1, place: "Walker.swift:10:3", seconds: 50),
            ],
            workers: 2
        ))
    }

    func test_whileNoneFinishes_aLineIsDueEachMinute() {
        let sut = heartbeat(workers: 1, startingAt: at(0))
        sut.started("Rules.swift:42:17", on: 0, at: at(0))

        XCTAssertNotNil(sut.due(at: at(65)))
        XCTAssertEqual(sut.secondsUntilDue(at: at(65)), 60)
        XCTAssertNil(sut.due(at: at(124)))
        XCTAssertEqual(sut.due(at: at(125))?.runs.map(\.seconds), [125])
    }

    func test_aMutantThatFinishes_putsTheLineOffAMinute() {
        let sut = heartbeat(workers: 2, startingAt: at(0))
        sut.started("Rules.swift:42:17", on: 0, at: at(0))
        sut.started("Walker.swift:10:3", on: 1, at: at(0))

        sut.finished(on: 1, at: at(50))

        XCTAssertNil(sut.due(at: at(100)))
        XCTAssertEqual(sut.secondsUntilDue(at: at(100)), 10)
        XCTAssertEqual(sut.due(at: at(110))?.runs.map(\.place), ["Rules.swift:42:17"])
    }

    // As between one mutant's end and the next one's start. The next check is a minute on, not at once.
    func test_withNoMutantUnderWay_noLineIsDue() {
        let sut = heartbeat(workers: 1, startingAt: at(0))

        XCTAssertNil(sut.due(at: at(90)))
        XCTAssertEqual(sut.secondsUntilDue(at: at(90)), 60)
    }

    // The clock stands still while SwiftMutator is suspended, so a wait can end before the line is due.
    func test_beforeTheLineIsDue_aCheckChangesNothing() {
        let sut = heartbeat(workers: 1, startingAt: at(0))
        sut.started("Rules.swift:42:17", on: 0, at: at(0))

        XCTAssertNil(sut.due(at: at(30)))
        XCTAssertNotNil(sut.due(at: at(60)))
    }

    // As the timeouts' reruns don't, mutants that start again start afresh.
    func test_beginning_forgetsTheMutantsUnderWay() {
        let sut = heartbeat(workers: 2, startingAt: at(0))
        sut.started("Rules.swift:42:17", on: 0, at: at(0))

        sut.begin(workers: 1, at: at(100))

        XCTAssertNil(sut.due(at: at(159)))
        sut.started("Walker.swift:10:3", on: 0, at: at(100))
        XCTAssertEqual(
            sut.due(at: at(160)),
            StillTesting(runs: [.init(worker: 0, place: "Walker.swift:10:3", seconds: 60)], workers: 1)
        )
    }

    private func heartbeat(workers: Int, startingAt start: DispatchTime) -> Heartbeat {
        let heartbeat = Heartbeat()
        heartbeat.begin(workers: workers, at: start)
        return heartbeat
    }

    private func at(_ seconds: UInt64) -> DispatchTime {
        DispatchTime(uptimeNanoseconds: 1 + seconds * 1_000_000_000)
    }
}
