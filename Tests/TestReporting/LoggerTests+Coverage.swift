import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    // Each worker tests its share of the mutants while the others test theirs, so the time left is the longest
    // share's: 3 of 5 mutants for one of 2 workers.
    func test_theFirstEstimate_spreadsTheMutantsOverTheWorkers() {
        XCTAssertEqual(Logger.initialEstimate(remaining: 5, cycle: 50, workers: 2), 150)
        XCTAssertEqual(Logger.initialEstimate(remaining: 5, cycle: 50, workers: 1), 250)
    }

    // What went wrong, so it can be put right; nothing when nothing did.
    func test_projectCoverageDiscoveryFinished_saysWhyCoverageFailed() {
        sut.projectCoverageDiscoveryFinished(failureReason: nil)
        sut.projectCoverageDiscoveryFinished(failureReason: "there is no profile data at /b/codecov/default.profdata")

        XCTAssertEqual(printer.linesPassed, [
            """
            ❌ Gathering coverage failed: there is no profile data at /b/codecov/default.profdata.
            Proceeding with mutation testing anyway.
            Pass \("--skip-coverage argument".bold) to disable this step
            """,
        ])
    }

    // The output of a coverage run that ran is kept, and the message says where.
    func test_projectCoverageDiscoveryFinished_saysWhereTheCoverageRunsOutputIs() {
        sut.projectCoverageDiscoveryFinished(
            failureReason: "the coverage run failed (exit status 1): error: Build failed",
            log: "/logs/coverage run.log"
        )

        XCTAssertEqual(printer.linesPassed, [
            """
            ❌ Gathering coverage failed: the coverage run failed (exit status 1): error: Build failed.
            The coverage run's output is in \("/logs/coverage run.log".bold)
            Proceeding with mutation testing anyway.
            Pass \("--skip-coverage argument".bold) to disable this step
            """,
        ])
    }

    // Coverage was gathered, but a failed test that stopped early skipped code the baseline runs, whose mutants are
    // then left out. Up to five tests are named, as the copy's skipped files are.
    func test_projectCoverageTestsFailed_namesUpToFiveTests_andWhereTheOutputIs() {
        let tests = [FailedTestLine.FailedTest(name: "-[CTests.CTests test_a]", location: nil)]
            + (2 ... 6).map { FailedTestLine.FailedTest(name: "test\($0)()", location: "BTests.swift:\($0):5") }

        sut.projectCoverageTestsFailed(TestsFailedWithCoverage(
            tests: .init(tests: tests, total: 8, firstLine: nil),
            log: "/logs/coverage run.log"
        ))

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ 8 tests failed with coverage on, but coverage was still gathered from every test process:
              -[CTests.CTests test_a]
              test2() at BTests.swift:2:5
              test3() at BTests.swift:3:5
              test4() at BTests.swift:4:5
              test5() at BTests.swift:5:5
              … and 3 more
            Code a failed test would have run after it stopped reads as never run, so its mutants aren't tested.
            The coverage run's output is in \("/logs/coverage run.log".bold)
            """,
        ])
    }

    func test_projectCoverageTestsFailed_withOneTest_andNoLogFolder() {
        sut.projectCoverageTestsFailed(TestsFailedWithCoverage(
            tests: .init(tests: [.init(name: "sum()", location: "SumTests.swift:12:5")], total: 1, firstLine: nil),
            log: nil
        ))

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ 1 test failed with coverage on, but coverage was still gathered from every test process:
              sum() at SumTests.swift:12:5
            Code a failed test would have run after it stopped reads as never run, so its mutants aren't tested.
            """,
        ])
    }
}
