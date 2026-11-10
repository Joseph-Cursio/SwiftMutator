@testable import muterCore
import XCTest

extension ResultsRecordTests {
    func test_aMutantRecordFromARun() throws {
        let log = """
        ◇ Test run started.
        ✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: sum(1, 2) == 3
        ✘ Test product() recorded an issue at ProductTests.swift:8:9: Expectation failed
        ✘ Test sum() recorded an issue at SumTests.swift:13:5: Expectation failed
        ✘ Test run with 2 tests in 2 suites failed after 0.1 seconds with 3 issues.
        """
        let schema = try makeSchema()
        let key = try XCTUnwrap(MutantKey.keys(for: [schema, schema], under: mutatedRoot).last)

        let run = TestRun(outcome: .failed, testLog: log, ending: .exited, exitStatus: 1)

        let record = MutantResult(
            key: key,
            schema: schema,
            finished: FinishedRun(index: 4, worker: 2, run: run, seconds: 31.2071),
            failures: MutantResult.failedTests(of: run),
            session: 1,
            finishedAt: finishedAt,
            log: "RelationalOperatorReplacement @ Sum.swift-73-22.log"
        )

        XCTAssertEqual(
            record,
            MutantResult(
                session: 1,
                path: "Sources/Sum.swift",
                line: 73,
                column: 22,
                occurrence: 1,
                utf8Offset: 3_361,
                mutationOperatorId: .ror,
                switchID: "Sum_670192af8b34c2a4_RelationalOperatorReplacement_73_22_3361",
                snapshot: .make(before: ">", after: "<", description: "changed > to <"),
                outcome: .failed,
                endedBy: .exited,
                exitStatus: 1,
                durationSeconds: 31.207,
                worker: 2,
                finishedAt: finishedAt,
                killedBy: [
                    FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5"),
                    FailedTestLine.FailedTest(name: "product()", location: "ProductTests.swift:8:9"),
                ],
                failedTestCount: 2,
                firstFailedTestLine: "✘ Test sum() recorded an issue at SumTests.swift:12:5: "
                    + "Expectation failed: sum(1, 2) == 3",
                log: "RelationalOperatorReplacement @ Sum.swift-73-22.log",
                fileSHA256: nil
            )
        )
    }

    func test_aMutantRecordFromARun_namesTheTestsACrashOrATimeoutShows() throws {
        let log = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Caught error\nFatal error: boom"

        let crash = try makeRecord(from: TestRun(outcome: .runtimeError, testLog: log, ending: .exited, exitStatus: 5))
        let timeout = try makeRecord(
            from: TestRun(outcome: .timeout, testLog: "◇ Test run started.", ending: .timedOut)
        )

        XCTAssertEqual(crash.killedBy, [FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertEqual(crash.failedTestCount, 1)
        XCTAssertEqual(timeout.killedBy, [])
        XCTAssertEqual(timeout.failedTestCount, 0)
        XCTAssertNil(timeout.firstFailedTestLine)
    }

    func test_aMutantRecordFromARun_namesNoTestsForASurvivorOrABuildError() throws {
        let log = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed"

        for outcome in [TestSuiteOutcome.passed, .buildError, .noCoverage] {
            let record = try makeRecord(from: TestRun(outcome: outcome, testLog: log, ending: .exited, exitStatus: 0))

            XCTAssertNil(record.killedBy, "\(outcome)")
            XCTAssertNil(record.failedTestCount, "\(outcome)")
            XCTAssertNil(record.firstFailedTestLine, "\(outcome)")
        }
    }

    func test_aMutantRecordFromARun_leavesOutTheTestsThePassingBaselinesLinesShowedFailing() throws {
        let lookalike = "✘ Test parsesAFailure() recorded an issue at ParserTests.swift:4:5: printed by the test"
        let real = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed"
        let configuration = MuterConfiguration().withUnreliableFailedTestLines(printedIn: [lookalike])
        let run = TestRun(outcome: .failed, testLog: lookalike + "\n" + real, ending: .exited, exitStatus: 1)

        let failures = try XCTUnwrap(MutantResult.failedTests(of: run, ignoring: configuration.failedTestLookalikes))

        XCTAssertEqual(failures.tests, [FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertEqual(failures.total, 1)
        XCTAssertEqual(failures.firstLine, real)
        // A run whose only such lines are the baseline's names no test.
        let lookalikeOnly = TestRun(outcome: .failed, testLog: lookalike, ending: .exited, exitStatus: 1)
        let none = try XCTUnwrap(
            MutantResult.failedTests(of: lookalikeOnly, ignoring: configuration.failedTestLookalikes)
        )
        XCTAssertEqual(none.tests, [])
        XCTAssertNil(none.firstLine)
        // A test the baseline didn't show failing is named even though failed-test lines aren't reliable.
        XCTAssertFalse(configuration.failedTestLinesAreReliable)
        XCTAssertEqual(MutantResult.failedTests(of: run)?.total, 2)
    }

    func test_aMutantRecordFromARun_roundsItsDurationToTheMillisecond_andHasAnExitStatusOnlyIfItExited() throws {
        let exited = try makeRecord(
            from: TestRun(outcome: .runtimeError, testLog: "", ending: .exited, exitStatus: 9),
            seconds: 1.23456
        )

        XCTAssertEqual(exited.durationSeconds, 1.235)
        XCTAssertEqual(exited.exitStatus, 9)
        XCTAssertEqual(exited.endedBy, .exited)
        for ending in [TestRun.Ending.timedOut, .stoppedAtFailedTest, .couldNotRun] {
            let record = try makeRecord(
                from: TestRun(outcome: .failed, testLog: "", ending: ending, exitStatus: 9),
                seconds: 0.0004
            )

            XCTAssertNil(record.exitStatus, "\(ending)")
            XCTAssertEqual(record.endedBy, ending)
            XCTAssertEqual(record.durationSeconds, 0)
        }
    }
}
