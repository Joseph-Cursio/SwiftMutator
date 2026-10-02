@testable import muterCore
import TestingExtensions
import XCTest

final class TestSuiteResultParsingTests: MuterTestCase {
    func test_logWithoutAnyError() {
        var contents = loadLogFile(named: "testRunWithoutFailures_withTestSucceededFooter.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .passed)

        contents = loadLogFile(named: "testRunWithoutFailures_withTestSucceededFooter_buckOutput.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .passed)
    }

    func test_logWithoutFailure() {
        var contents = loadLogFile(named: "testRunWithFailures_withoutTestFailedFooter.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)

        contents = loadLogFile(named: "testRunWithFailures_swift.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)

        contents = loadLogFile(named: "testRunWithFailures_withTestFailedFooter.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)

        contents = loadLogFile(named: "testRunWithFailures_withTestFailedFooter_singleTestFailure.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)

        contents = loadLogFile(named: "testRunWithFailures_withTestFailedFooter_noTestFailureCount.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)

        contents = loadLogFile(named: "testRunWithFailures_withTestFailedFooter_buckOutput.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)
    }

    func test_logWithFatalErrorAndErrorCodeZero() {
        let contents = loadLogFile(named: "runtimeError_fatalError.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .passed)
    }

    func test_logWithFatalErrorAndErrorCodeNotZero() {
        let contents = loadLogFile(named: "runtimeError_fatalError.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: -127), .runtimeError)
    }

    func test_logWithBuildError() {
        var contents = loadLogFile(named: "buildError_missingProjectFile.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .buildError)

        contents = loadLogFile(named: "buildError_runScriptStepFailed.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .buildError)

        contents = loadLogFile(named: "buildError_invalidSwiftCode.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .buildError)

        contents = loadLogFile(named: "buildError_withTestFailedFooter.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .buildError)

        contents = loadLogFile(named: "buildError_buckOutput.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .buildError)
    }

    private func loadLogFile(named name: String) -> String {
        guard let data = FileManager.default
            .contents(atPath: "\(fixturesDirectory)/TestLogsForParsing/\(name)"),
            let string = String(data: data, encoding: .utf8)
        else {
            fatalError("Unable to load a log file named \(name) for testing the XCTest result parser")
        }

        return string
    }

    // MARK: - Swift Testing

    func test_logWithSwiftTestingFailure() {
        var contents = loadLogFile(named: "testRunWithFailures_swiftTesting.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 1), .failed)

        contents = loadLogFile(named: "testRunWithFailures_swiftTesting_multipleIssues.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 1), .failed)
    }

    func test_logWithSwiftTestingSuccess() {
        let contents = loadLogFile(named: "testRunWithoutFailures_swiftTesting.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .passed)
    }

    func test_logWithSwiftTestingFailureAndExitCodeZero() {
        // Special case: log says "failed" even if exit code is 0
        let contents = loadLogFile(named: "testRunWithFailures_swiftTesting.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 0), .failed)
    }

    // MARK: - Runs stopped at the time limit

    func test_stoppedRunWithoutEvidenceOfAKill_isATimeout() {
        var contents = """
        Test Suite 'All tests' started at 2026-10-02 09:55:30.877.
        Test Case '-[ExampleTests.ExampleTests testHangs]' started.
        """
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .timeout)

        contents = loadLogFile(named: "testRunWithoutFailures_withTestSucceededFooter.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .timeout)

        // Stopping the run kills the test process with SIGKILL first, and `swift test` may report
        // that before it is killed too. That's our own kill, not a crash.
        contents = """
        Test Case '-[ExampleTests.ExampleTests testHangs]' started.
        error: Process '/path/to/xctest /path/to/ExamplePackageTests.xctest' exited with unexpected signal code 9
        """
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .timeout)
    }

    func test_stoppedRunWhoseLogShowsACrash_isARuntimeError() {
        // Stopped while xcodebuild was relaunching the runner after the crash.
        var contents = loadLogFile(named: "timeout_xcodebuildCrash.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .runtimeError)

        contents = loadLogFile(named: "runtimeError_fatalError.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .runtimeError)

        // SwiftPM's report of a test process killed by a signal, with no Swift runtime message.
        contents = """
        Test Case '-[BonMotTests.XMLTagStyleBuilderTests testComposition]' started.
        error: Process '/path/to/xctest /path/to/BonMotPackageTests.xctest' exited with unexpected signal code 11
        """
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .runtimeError)
    }

    func test_stoppedRunWhoseLogShowsATestFailure_isFailed() {
        // Stopped after a test failed but before any suite summary was printed.
        var contents = loadLogFile(named: "timeout_xcodebuildFailedTestCase.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .failed)

        contents = loadLogFile(named: "testRunWithFailures_swiftTesting.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .failed)

        // As for a finished run, a test failure outranks a crash.
        contents = loadLogFile(named: "timeout_xcodebuildFailedTestCase.log") + loadLogFile(named: "timeout_xcodebuildCrash.log")
        XCTAssertEqual(TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout), .failed)
    }
}
