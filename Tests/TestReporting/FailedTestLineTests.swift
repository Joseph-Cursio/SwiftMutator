@testable import muterCore
import XCTest

final class FailedTestLineTests: XCTestCase {
    private let escape = "\u{1B}"
    /// SF Symbols' xmark.diamond.fill, which Swift Testing prints instead of ✘ when SF Pro is installed.
    private let sfSymbolsCross = "\u{100884}"

    func test_swiftTestingIssueLines_match() {
        assertMatch([
            // Swift 6.4, then 6.3.3, which writes the expectation's values differently.
            "✘ Test computeInC() recorded an issue at CTests.swift:28:9: Expectation failed: compute(5) == 10",
            "✘ Test computeInC() recorded an issue at CTests.swift:28:9: Expectation failed: (compute(5) → 11) == 10",
            // Parameterized tests.
            "✘ Test sum(of:) recorded an issue with 1 argument of → 5 at A.swift:3:5: Expectation failed",
            "✘ Test sum(a:b:) recorded an issue with 2 arguments a → 1, b → 2 at A.swift:3:5: x",
            "✘ Suite CTests recorded an issue at C.swift:1:1: Caught error: x",
            "✘ Test «unknown» recorded an issue: Caught error: x",
            "✘ Test \"Adds fast\" recorded an issue at A.swift:1:1: x",
            "\(escape)[91m✘\(escape)[0m Test a() recorded an issue at A.swift:1:1: x",
            "\(sfSymbolsCross) Test a() recorded an issue at A.swift:1:1: x",
            "\(sfSymbolsCross)  Test a() recorded an issue at A.swift:1:1: x",
            // With ANSI codes on, the SF Symbols symbol's trailing space is inside the colour code.
            "\(escape)[91m\(sfSymbolsCross) \(escape)[0m Test a() recorded an issue at A.swift:1:1: x",
            // Tag colour dots between the symbol and the test.
            "\(escape)[91m✘\(escape)[0m \(escape)[38;5;208m●\(escape)[96m●\(escape)[0m Test a() recorded an issue at A.swift:1:1: x",
        ])
    }

    func test_xctestFailedTestCaseLines_match() {
        assertMatch([
            "Test Case '-[BTests.BXCTests testIncrement]' failed (0.048 seconds).",
            "Test Case 'BXCTests.testIncrement' failed (0.048 seconds).",
        ])
    }

    func test_knownIssuesWarningsAndRunEndLines_doNotMatch() {
        assertNoMatch([
            "━ Test knownIssueAlways() recorded a known issue at ATests.swift:34:13: Expectation failed: 1 == 2",
            "⚠︎ Test recordsWarning() recorded a warning at CTests.swift:35:21: Issue recorded",
            "✘ Test computeInC() failed after 0.004 seconds with 1 issue.",
            "✘ Test run with 13 tests in 3 suites failed after 5.151 seconds with 1 issue.",
            "Note: Some test targets reported failures:",
            "  - CTests (Swift Testing)",
        ])
    }

    func test_failureTextInsideOrBelowAnotherLine_doesNotMatch() {
        assertNoMatch([
            // A parameterized test's argument, quoted inside the line that starts its test case.
            "◇ Test case passing 1 argument s → \"✘ Test a() recorded an issue at A.swift:1:1: x\" to f() started.",
            "↳ ✘ Test a() recorded an issue at A.swift:1:1: x",
            "  ✘ Test a() recorded an issue at A.swift:1:1: x",
            // A test's own output without a line break of its own.
            "partial output✘ Test a() recorded an issue at A.swift:1:1: x",
            "[SwiftMutator] The line that stopped it: ✘ Test a() recorded an issue at A.swift:1:1: x",
        ])
    }

    func test_otherXCTestLines_doNotMatch() {
        assertNoMatch([
            "Test Case '-[BTests.BXCTests testIncrement]' passed (0.001 seconds).",
            "Test Case '-[BTests.BXCTests testIncrement]' started.",
            "/a/BXCTests.swift:7: error: -[BTests.BXCTests testIncrement] : XCTAssertEqual failed: (\"0\") is not equal to (\"2\")",
            "Test Suite 'All tests' failed at 2026-10-02 13:16:00.000.",
            "  Test Case '-[A.B c]' failed (0.1 seconds).",
        ])
    }

    func test_passingRunFixtures_containNoFailedTestLine() {
        for name in [
            "testRunWithoutFailures_swiftTesting.log",
            "testRunWithoutFailures_withTestSucceededFooter.log",
            "testRunWithoutFailures_withTestSucceededFooter_buckOutput.log",
        ] {
            XCTAssertNil(FailedTestLine.first(inLog: loadLogFile(named: name)), name)
        }
    }

    func test_failingRunFixtures_containAFailedTestLine() {
        for name in [
            "testRunWithFailures_swift.log",
            "testRunWithFailures_swiftTesting.log",
            "testRunWithFailures_swiftTesting_multipleIssues.log",
            "testRunWithFailures_withTestFailedFooter.log",
            "testRunWithFailures_withTestFailedFooter_singleTestFailure.log",
            "testRunWithFailures_withoutTestFailedFooter.log",
            "timeout_xcodebuildFailedTestCase.log",
        ] {
            XCTAssertNotNil(FailedTestLine.first(inLog: loadLogFile(named: name)), name)
        }

        XCTAssertEqual(
            FailedTestLine.first(inLog: loadLogFile(named: "testRunWithFailures_swiftTesting_multipleIssues.log")),
            "✘ Test addition() recorded an issue at MathTests.swift:8:5: Expectation failed"
        )
        XCTAssertEqual(
            FailedTestLine.first(inLog: loadLogFile(named: "timeout_xcodebuildFailedTestCase.log")),
            "Test Case '-[FFCParserCombinatorTests.FFCParserCombinatorTests testFlatMap]' failed (0.528 seconds)."
        )
    }

    func test_first_returnsTheFirstFailedTestLineWithoutColourCodes() {
        let log = """
        \(escape)[1m◇\(escape)[0m Test run started.
        \(escape)[91m✘\(escape)[0m Test a() recorded an issue at A.swift:1:1: x
        \(escape)[91m✘\(escape)[0m Test b() recorded an issue at B.swift:2:2: y
        """

        XCTAssertEqual(FailedTestLine.first(inLog: log), "✘ Test a() recorded an issue at A.swift:1:1: x")
    }

    // In Swift, "\r\n" is one Character, so splitting a log at "\n" alone leaves such a log in one piece.
    func test_first_findsALineInALogWithCRLFLineBreaks() {
        let log = "◇ Test run started.\r\n✘ Test a() recorded an issue at A.swift:1:1: x\r\n"

        XCTAssertEqual(FailedTestLine.first(inLog: log), "✘ Test a() recorded an issue at A.swift:1:1: x")
    }

    func test_withoutColours_removesANSICodes() {
        XCTAssertEqual(
            FailedTestLine.withoutColours(
                "\(escape)[91m✘\(escape)[0m \(escape)[38;5;208m●\(escape)[0m Test a() recorded an issue"
            ),
            "✘ ● Test a() recorded an issue"
        )
        XCTAssertEqual(FailedTestLine.withoutColours("Test Case 'a' failed ("), "Test Case 'a' failed (")
    }

    private func assertMatch(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines {
            XCTAssertTrue(FailedTestLine.matches(text), text.debugDescription, file: file, line: line)
        }
    }

    private func assertNoMatch(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines {
            XCTAssertFalse(FailedTestLine.matches(text), text.debugDescription, file: file, line: line)
        }
    }

    private func loadLogFile(named name: String) -> String {
        let path = "\(fixturesDirectory)/TestLogsForParsing/\(name)"
        guard let data = FileManager.default.contents(atPath: path) else {
            XCTFail("Unable to load the log file \(path)")
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
