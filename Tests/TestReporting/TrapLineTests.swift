@testable import muterCore
import XCTest

final class TrapLineTests: XCTestCase {
    private let escape = "\u{1B}"

    func test_theRuntimesMessages_match_andAreFoundInALog() {
        let lines = [
            "Sample/Sample.swift:12: Fatal error: Index out of range",
            "Sample/Sample.swift:12: Fatal error",
            "Sample/Sample.swift:7: Precondition failed: negative",
            "Sample/Sample.swift:9: Assertion failed",
            "Fatal error: Unexpectedly found nil while unwrapping an Optional value",
        ]

        for line in lines {
            XCTAssertTrue(TrapLine.matches(line), line)
            XCTAssertEqual(TrapLine.first(inLog: "Test Suite 'All tests' started.\n\(line)\nmore"), line)
        }
    }

    // A line coloured before the message is found by both, so what would stop a mutant's run is what a passing run's
    // lookalike check finds.
    func test_aColouredLine_isFoundAsItMatches() {
        let line = "\(escape)[31mFatal error: caught by the test\(escape)[0m"

        XCTAssertTrue(TrapLine.matches(line))
        XCTAssertEqual(TrapLine.first(inLog: "one\r\n\(line)\r\ntwo"), line)
    }

    func test_otherLines_dontMatch_andAreNotFound() {
        let lines = [
            "Test Case '-[AppTests.SumTests testFatalErrors]' passed (0.001 seconds).",
            "Fatal errors: 0",
            "the Fatal error: path",
            "Sample.swift:12: warning: Assertion failedx",
        ]

        for line in lines {
            XCTAssertFalse(TrapLine.matches(line), line)
        }
        XCTAssertNil(TrapLine.first(inLog: lines.joined(separator: "\n")))
    }
}
