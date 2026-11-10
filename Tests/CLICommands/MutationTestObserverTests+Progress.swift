@testable import muterCore
import XCTest

extension MutationTestObserverTests {
    func test_configurationKeysUnknown_isPrinted() throws {
        try sut.start()

        runEvents.send(
            .configurationKeysUnknown(
                [.init(key: "mutationTestTimeOut", closest: "mutationTestTimeout")],
                file: "ci.yml"
            )
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ ci.yml: \("mutationTestTimeOut".bold) isn't a configuration key, so it is ignored. "
                + "Did you mean \("mutationTestTimeout".bold)?"
        )
    }

    func test_stopAtFirstFailureTurnedOff_isPrinted() throws {
        try sut.start()

        runEvents.send(.stopAtFirstFailureTurnedOff(reason: "the reason"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: the reason"
        )
    }

    func test_workersShareUserDefaults_isPrinted() throws {
        try sut.start()

        runEvents.send(.workersShareUserDefaults)

        XCTAssertEqual(
            printer.linesPassed.last,
            "ℹ️ Workers running through `swift test` share `UserDefaults.standard`: tests that write to it can fail "
                + "each other and kill mutants they don't check. See \"Tests that share state across workers\" in "
                + "the README."
        )
    }

    func test_resumePlanned_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(
            .resumePlanned(
                ResumeSummary.make(
                    path: "/logs/results.jsonl",
                    reused: 3,
                    toTest: 1,
                    retestedBecause: [.buildError: 1]
                )
            )
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 3 results still hold, "
                + "so 1 mutant is left to test (1 build error)."
        )
    }

    // The time left is the rate since the mutants started, which the Logger only knows from this event. Without
    // it, the bar would show its first estimate until 100%.
    func test_mutantRunsStarted_reachesTheLogger() throws {
        let milliseconds = Locked<UInt64>(1_000_000)
        current.instant = { DispatchTime(uptimeNanoseconds: milliseconds.value * 1_000_000) }
        try sut.start()
        runEvents.send(.resumePlanned(ResumeSummary.make(reused: 0, toTest: 10, retestedBecause: [.notRecorded: 10])))
        // 10 mutants, 120 s each, on one worker.
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(timePerBuildTestCycle: 120, remainingMutationPointsCount: 10))
        )

        runEvents.send(.mutantRunsStarted)
        milliseconds.change { $0 += 60_000 }
        runEvents.send(.newTestLogAvailable(MutationTestLog.make(mutationPoint: .make())))

        let draw = printer.linesPassed.last { $0.contains("ETC:") } ?? ""
        // 60 s a mutant, and 9 left. The first estimate would say 20 min.
        XCTAssertTrue(draw.hasSuffix("ETC: 9 min"), draw)
    }

    // Without a terminal, each mutant's result is a line of progress, which the Logger only gets from this event.
    func test_aMutantsOutcome_reachesTheLogger_forItsLineOfProgress() throws {
        current.standardOutIsATerminal = false
        try sut.start()
        runEvents.send(.resumePlanned(ResumeSummary.make(reused: 0, toTest: 2, retestedBecause: [.notRecorded: 2])))
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2))
        )

        runEvents.send(.newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation.make()))

        let line = printer.linesPassed.last ?? ""
        XCTAssertTrue(line.hasPrefix("[02:42:00] 1 of 2 (50%) | 1 survived | "), line)
    }

    func test_resultsFileCreated_isLogged_andNamedAtTheEnd() throws {
        try sut.start()

        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)"
        )

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.make()))

        XCTAssertEqual(printer.linesPassed.last, "💾 Each mutant's result is in \("/logs/results.jsonl".bold)")
    }
}
