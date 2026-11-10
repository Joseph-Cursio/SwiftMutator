@testable import muterCore
import XCTest

extension FailedTestLineTests {
    /// The escape character that starts a terminal's colour codes.
    var escape: String { "\u{1B}" }

    typealias FailedTest = FailedTestLine.FailedTest
    typealias FailedTests = FailedTestLine.FailedTests

    func assertMatch(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines {
            XCTAssertTrue(FailedTestLine.matches(text), text.debugDescription, file: file, line: line)
            // The same check decides both, so a line that would stop a run names its test.
            XCTAssertNotNil(FailedTestLine.failedTest(in: text), text.debugDescription, file: file, line: line)
        }
    }

    func assertNoMatch(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines {
            XCTAssertFalse(FailedTestLine.matches(text), text.debugDescription, file: file, line: line)
            XCTAssertNil(FailedTestLine.failedTest(in: text), text.debugDescription, file: file, line: line)
        }
    }

    func loadLogFile(named name: String) -> String {
        let path = "\(fixturesDirectory)/TestLogsForParsing/\(name)"
        guard let data = FileManager.default.contents(atPath: path) else {
            XCTFail("Unable to load the log file \(path)")
            return ""
        }
        return String(lossyUTF8: data)
    }
}
