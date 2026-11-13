@testable import muterCore
import XCTest

extension MutationTestObserverTests {
    func test_whyCoverageFailed_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(
            .projectCoverageDiscoveryFinished(CoverageFailure(reason: "llvm-cov failed", log: "/logs/coverage run.log"))
        )
        runEvents.send(.projectCoverageDiscoveryFinished(nil))

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            printer.linesPassed.first?.hasPrefix(
                        "❌ Gathering coverage failed: llvm-cov failed.\n"
                            + "The coverage run's output is in \("/logs/coverage run.log".bold)\n"
                    ),
            true
        )
    }

    func test_testsThatFailedWithCoverageOn_reachTheLogger() throws {
        try sut.start()

        runEvents.send(
            .projectCoverageTestsFailed(TestsFailedWithCoverage(
                tests: .init(tests: [.init(name: "sum()", location: nil)], total: 1, firstLine: nil),
                log: nil
            ))
        )

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ 1 test failed with coverage on, but coverage was still gathered from every test process:
              sum()
            Code a failed test would have run after it stopped reads as never run, so its mutants aren't tested.
            """,
        ])
    }

    // The step that ran each test keeps its log, by moving the file the run wrote (`FileSystemManager.keepLog`), so
    // the observer writes none: a second write of every log would double what a run writes to disk.
    func test_aTestLog_isNotWrittenByTheObserver() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let mutationPoint = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "/project/Sources/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )

        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(
                testLog: "Executed 3 tests, with 0 failures",
                timePerBuildTestCycle: 1,
                remainingMutationPointsCount: 1
            ))
        )
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(
                mutationPoint: mutationPoint,
                testLog: "Executed 3 tests, with 1 failure",
                keptFileName: "RemoveSideEffects @ file2.swift-5-6 9c3e04a1d8f2b7e6 (#2).log"
            ))
        )

        XCTAssertFalse(
            fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"), "\(fileManager.methodCalls)"
        )
    }

    // The step keeps its log beside the first run's.
    func test_aRerun_isSaid_withoutCountingTheProgress() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let point = MutationPoint.make(filePath: "/project/Sources/Sum.swift", position: 3)
        let keptFileName = "RelationalOperatorReplacement @ Sum.swift-3-3 670192af8b34c2a4 (rerun).log"

        runEvents.send(
            .timeoutRerunFinished(TimeoutRerun(
                rerun: .make(testSuiteOutcome: .failed, point: point),
                log: .make(
                    mutationPoint: point, testLog: "Executed 3 tests, with 1 failure", keptFileName: keptFileName
                ),
                seconds: 12,
                number: 1,
                count: 1
            ))
        )

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(printer.linesPassed, ["🔁 1 of 1 killed at Sum.swift:3:3, in 12 s"])
    }

    // The step keeps the first run's log beside the log of the run that replaced it, which the mutant's line names.
    // Neither is counted in the progress.
    func test_aRunRepeatedAfterALaunchFailure_isSaid_namingTheFirstRunsLog() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let point = MutationPoint.make(filePath: "/project/Sources/Sum.swift", position: 3)
        let keptFileName = "RelationalOperatorReplacement @ Sum.swift-3-3 670192af8b34c2a4 (launch failed).log"

        runEvents.send(
            .runRepeatedAfterLaunchFailure(RepeatedRun(
                mutant: .make(testSuiteOutcome: .failed, point: point),
                worker: 1,
                line: "Simulator device failed to launch com.example.App.",
                log: .make(mutationPoint: point, testLog: "** TEST EXECUTE FAILED **", keptFileName: keptFileName)
            ))
        )

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertTrue(printer.linesPassed[0].hasPrefix("🔁 The simulator didn't launch the tests for Sum.swift:3:3"))
    }

    // The step keeps the first run's log beside the log of the baseline that replaced it, before any progress.
    func test_aBaselineRepeatedAfterALaunchFailure_isSaid_namingTheFirstRunsLog() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let keptFileName = "baseline run (launch failed).log"

        runEvents.send(.baselineRepeatedAfterLaunchFailure(
            line: "Simulator device failed to launch com.example.App.",
            log: .make(testLog: "** TEST FAILED **", keptFileName: keptFileName)
        ))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(printer.linesPassed, [
            "🔁 The simulator didn't launch the baseline's tests, so they ran again. "
                + "The first run's log, baseline run (launch failed).log, says: "
                + "Simulator device failed to launch com.example.App.",
        ])
    }

    // The first run's timeout wasn't a survivor the Xcode format warns of, so a rerun that survives is warned of
    // then. One that timed out again changed nothing.
    func test_aTimeoutThatSurvivesItsRerun_isWarnedOf_inTheXcodeFormat() throws {
        options = .make(reportFormat: .xcode)
        try sut.start()
        let point = MutationPoint.make(filePath: "/project/Sources/Sum.swift", position: 3)
        let rerun = { (outcome: TestSuiteOutcome) in
            TimeoutRerun(
                rerun: .make(testSuiteOutcome: outcome, point: point), log: .make(), seconds: 12, number: 1, count: 2
            )
        }

        runEvents.send(.timeoutRerunFinished(rerun(.timeout)))
        XCTAssertEqual(printer.linesPassed.filter { $0.contains("warning:") }, [])
        runEvents.send(.timeoutRerunFinished(rerun(.passed)))

        XCTAssertEqual(printer.linesPassed.filter { $0.contains("warning:") }.count, 1, "\(printer.linesPassed)")
        XCTAssertTrue(flushStandardOut.flushHandlerWasCalled)
    }
}
