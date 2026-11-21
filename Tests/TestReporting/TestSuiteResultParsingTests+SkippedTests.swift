@testable import muterCore
import XCTest

extension TestSuiteResultParsingTests {
    // XCTest names its skipped tests before its failures, so a run that skipped some and failed reads as failed, not
    // as a runtime error from its exit status alone. BonMot skips 3 of its 85 tests.
    func test_anXCTestRunWithSkippedTestsAndAFailure_isFailed() {
        let summaries = [
            "Executed 85 tests, with 3 tests skipped and 1 failure (0 unexpected) in 0.104 (0.107) seconds",
            "Executed 85 tests, with 3 tests skipped and 32 failures (0 unexpected) in 0.104 (0.107) seconds",
            "Executed 5 tests, with 1 test skipped and 2 failures (2 unexpected) in 0.010 (0.011) seconds",
        ]
        for summary in summaries {
            let log = """
                Test Suite 'BonMotTests.xctest' failed at 2026-11-20 14:23:20.054.
                \t \(summary)
                """
            XCTAssertEqual(TestSuiteOutcome.from(testLog: log, terminationStatus: 1), .failed, summary)
        }
        // Linux's XCTest, seen in swift:6.4-noble, says it the same way.
        let linuxLog = """
            Test Case 'LTests.testSkipped' skipped (0.0 seconds)
            Test Suite 'Debug-linux-aarch64.xctest' failed at 2026-11-20 22:40:01.112
            \t Executed 3 tests, with 1 test skipped and 1 failure (0 unexpected) in 0.0 (0.0) seconds
            """
        XCTAssertEqual(TestSuiteOutcome.from(testLog: linuxLog, terminationStatus: 1), .failed)
    }

    func test_anXCTestRunWithSkippedTestsAndNoFailure_passes() {
        let log = """
            Test Suite 'BonMotTests.xctest' passed at 2026-11-20 14:23:20.054.
            \t Executed 85 tests, with 3 tests skipped and 0 failures (0 unexpected) in 0.104 (0.107) seconds
            """
        XCTAssertEqual(TestSuiteOutcome.from(testLog: log, terminationStatus: 0), .passed)
        // A crash after it is still a runtime error: nothing in the log counts a failure.
        XCTAssertEqual(TestSuiteOutcome.from(testLog: log, terminationStatus: 1), .runtimeError)
    }
}
