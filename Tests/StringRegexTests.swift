@testable import muterCore
import XCTest

final class StringRegexTests: XCTestCase {
    func test_firstMatchOf_givesTheWholeMatch() {
        XCTAssertEqual("BUILD_DIR = /a/b".firstMatchOf("BUILD_DIR = (.+)"), "BUILD_DIR = /a/b")
    }

    func test_firstCaptureOf_givesTheFirstGroup() {
        XCTAssertEqual("BUILD_DIR = /a/b".firstCaptureOf("BUILD_DIR = (.+)"), "/a/b")
    }

    func test_firstCaptureOf_isNilWhenNothingMatches() {
        XCTAssertNil("SYMROOT = /a/b".firstCaptureOf("BUILD_DIR = (.+)"))
    }

    func test_firstCaptureOf_isNilWhenThePatternHasNoGroup() {
        XCTAssertNil("BUILD_DIR = /a/b".firstCaptureOf("BUILD_DIR = .+"))
    }

    func test_firstCaptureOf_isNilWhenTheGroupTakesNoPartInTheMatch() {
        XCTAssertNil("abc".firstCaptureOf("(x)?abc"))
    }

    // NSRegularExpression counts UTF-16 units. A range of the string's Characters is shorter whenever one of them
    // takes more than one unit, as an emoji, a decomposed accent or a CRLF line ending does, and cut off the match.
    func test_searchesTheWholeString_afterCharactersOfSeveralUTF16Units() {
        let text = "👍 Cafe\u{301}\r\nBUILD_DIR = /a/b"

        XCTAssertEqual(text.firstCaptureOf("BUILD_DIR = (.+)"), "/a/b")
        XCTAssertEqual(text.firstMatchOf("/a/b"), "/a/b")
        XCTAssertTrue(text.matches("/a/b$"))
        XCTAssertEqual(text.stringsMatchingRegex("/[ab]"), ["/a", "/b"])
    }
}
