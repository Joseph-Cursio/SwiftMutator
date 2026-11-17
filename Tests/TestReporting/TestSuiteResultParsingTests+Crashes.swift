@testable import muterCore
import XCTest

// A run stopped at the time limit whose log shows a crash, as the Swift runtime's trap message or xcodebuild's restart
// line show one.
extension TestSuiteResultParsingTests {
    // A `precondition` or `assert` traps as `fatalError` does, with its own word for it. Yams under xcodebuild: every
    // test crashed, and xcodebuild relaunched the runner for each until the time limit.
    func test_stoppedRunWhoseLogShowsAPreconditionOrAssertion_isARuntimeError() {
        XCTAssertEqual(
            TestSuiteOutcome.from(
                testLog: loadLogFile(named: "timeout_xcodebuildPreconditionCrash.log"),
                terminationStatus: 9,
                timeoutExecution: .timeout
            ),
            .runtimeError
        )
        // The runtime adds `: message` only when there is one.
        for trap in ["Fatal error", "Precondition failed", "Assertion failed", "Fatal error: Index out of range"] {
            let contents = """
            Test Case '-[ExampleTests.ExampleTests testSum]' started.
            Example/Sum.swift:12: \(trap)
            """
            XCTAssertEqual(
                TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout),
                .runtimeError,
                trap
            )
        }
    }

    // A test's own text that only mentions a trap isn't the runtime's message for one: the word must follow `: ` or
    // start the line, and end it or be followed by `: `.
    func test_stoppedRunWhoseLogOnlyMentionsATrap_isATimeout() {
        let contents = """
        Test Case '-[ExampleTests.ExampleTests testSum]' started.
        checking that a Precondition failed message is shown
        counters: Assertion failedCount is 0
        Fatal errors: 0
        """
        XCTAssertEqual(
            TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout),
            .timeout
        )
    }

    // A test that catches a trap (Nimble's `throwAssertion`) prints the runtime's message and passes, so a passing
    // baseline that printed one leaves it showing nothing, as with a failed-test lookalike. SwiftPM's signal line
    // still counts: no process that printed it went on.
    func test_stoppedRunWhoseTrapLineIsUnreliable_isATimeout() {
        XCTAssertEqual(
            TestSuiteOutcome.from(
                testLog: loadLogFile(named: "timeout_xcodebuildPreconditionCrash.log"),
                terminationStatus: 9,
                timeoutExecution: .timeout,
                failedTestLinesAreReliable: false
            ),
            .timeout
        )
        let signal = """
        Test Case '-[BonMotTests.XMLTagStyleBuilderTests testComposition]' started.
        error: Process '/path/to/xctest /path/to/BonMotPackageTests.xctest' exited with unexpected signal code 11
        """
        XCTAssertEqual(
            TestSuiteOutcome.from(
                testLog: signal, terminationStatus: 9, timeoutExecution: .timeout, failedTestLinesAreReliable: false
            ),
            .runtimeError
        )
    }

    // A crash with no Swift message, such as a bad access, shows only as xcodebuild's restart line. It counts while
    // failed-test lines are reliable: a passing baseline that printed it, retrying a failed test, makes them
    // unreliable.
    func test_stoppedRunWhoseLogShowsXcodebuildsRestart_isARuntimeErrorWhileLinesAreReliable() {
        let contents = """
        Test Case '-[ExampleTests.ExampleTests testParse]' started.

        Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

        Test Suite 'Selected tests' started at 2026-11-17 11:28:56.523.
        Test Case '-[ExampleTests.ExampleTests testPrint]' started.
        """
        XCTAssertEqual(
            TestSuiteOutcome.from(testLog: contents, terminationStatus: 9, timeoutExecution: .timeout),
            .runtimeError
        )
        XCTAssertEqual(
            TestSuiteOutcome.from(
                testLog: contents, terminationStatus: 9, timeoutExecution: .timeout, failedTestLinesAreReliable: false
            ),
            .timeout
        )
        // Only at the start of a line, as xcodebuild prints it.
        let quoted = "Test Case '-[ExampleTests.ExampleTests testParse]' started.\nlog: Restarting after unexpected "
            + "exit, crash, or test timeout"
        XCTAssertEqual(
            TestSuiteOutcome.from(testLog: quoted, terminationStatus: 9, timeoutExecution: .timeout),
            .timeout
        )
    }
}
