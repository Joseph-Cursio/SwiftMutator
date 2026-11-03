import Foundation
@testable import muterCore
import TestingExtensions

/// What the logger says of the mutants under way once none has finished for a while.
final class LoggerStillTestingTests: MuterTestCase {
    private let sut = Logger()

    private let twoWorkers = StillTesting(
        runs: [
            .init(worker: 0, place: "Rules.swift:42:17", seconds: 75.8),
            .init(worker: 1, place: "Walker.swift:10:3", seconds: 61),
        ],
        workers: 2
    )

    // A line as the progress lines are, starting with the time of day, and with no "killed" or file's place first.
    func test_withoutATerminal_namesEachWorkersMutant_andHowLongItHasRun() {
        current.standardOutIsATerminal = false
        startTheLines()

        sut.stillTesting(twoWorkers)

        XCTAssertEqual(
            printer.linesPassed.last,
            "[02:42:00] still testing | worker 1: Rules.swift:42:17 for 75 s | worker 2: Walker.swift:10:3 for 61 s"
        )
    }

    func test_withOneWorker_namesNoWorker() {
        current.standardOutIsATerminal = false
        startTheLines()

        sut.stillTesting(StillTesting(runs: [.init(worker: 0, place: "Rules.swift:42:17", seconds: 125)], workers: 1))

        XCTAssertEqual(printer.linesPassed.last, "[02:42:00] still testing | Rules.swift:42:17 for 125 s")
    }

    // The bar redraws itself, and a line would break that.
    func test_onATerminal_printsNothing() {
        startTheLines()
        let printedBefore = printer.linesPassed.count

        sut.stillTesting(twoWorkers)

        XCTAssertEqual(printer.linesPassed.count, printedBefore)
    }

    /// The baseline's log, which starts the bar or the lines.
    private func startTheLines() {
        sut.resumePlanned(.make(reused: 0, toTest: 2, retestedBecause: [.notRecorded: 2]))
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2)
        )
    }
}
