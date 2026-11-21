@testable import muterCore
import XCTest

extension MutationTestObserverTests {
    // --quiet reaches the Logger as the observer starts, so that the banner is quiet too. A warning and the
    // summary still print; the banner, the update check, discovery, notices and progress don't.
    func test_quiet_printsNoBannerDiscoveryNoticesOrProgress_butAWarningAndTheSummary() throws {
        current.standardOutIsATerminal = false
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"), quiet: true)
        try sut.start()

        runEvents.send(.muterLaunched)
        runEvents.send(.updateCheckStarted)
        runEvents.send(.updateCheckFinished(newVersion: "99.0.0"))
        runEvents.send(.configurationKeysUnknown([.init(key: "timeOut", closest: nil)], file: "ci.yml"))
        runEvents.send(.sourceFileDiscoveryStarted)
        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryStarted)
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))
        runEvents.send(.workersShareUserDefaults)
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        runEvents.send(.mutationTestingStarted)
        runEvents.send(.resumePlanned(ResumeSummary.make(reused: 0, toTest: 2, retestedBecause: [.notRecorded: 2])))
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2))
        )
        runEvents.send(.mutantRunsStarted)
        runEvents.send(.newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation.make()))

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ ci.yml: \("timeOut".bold) isn't a configuration key, so it is ignored.",
        ])

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.make()))

        XCTAssertTrue(printer.linesPassed.contains("📝 Report generated: \("/out/report.txt".bold)"))
        XCTAssertEqual(printer.linesPassed.last, "💾 Each mutant's result is in \("/logs/results.jsonl".bold)")
    }

    // The flag is the run's alone: a Logger no quiet run has started prints its notices.
    func test_withoutQuiet_theLoggerIsntQuiet() throws {
        try sut.start()

        XCTAssertFalse(current.logger.quiet)
        runEvents.send(.workersShareUserDefaults)
        XCTAssertEqual(printer.linesPassed.count, 1)
    }
}
