@testable import muterCore
import XCTest

final class ChangedFileTests: XCTestCase {
    private let file = ChangedFile(
        path: "A.swift",
        sha256: "",
        lines: [LineRange(first: 10, last: 12), LineRange(first: 30, last: 30)],
        deletionsAfter: [20]
    )

    func test_codeOnAChangedLine_isChanged() {
        XCTAssertTrue(file.isChanged(11...11))
        XCTAssertTrue(file.isChanged(30...30))
    }

    // A statement over several lines, changed on its first one only.
    func test_codeSpanningAChangedLine_isChanged() {
        XCTAssertTrue(file.isChanged(8...10))
        XCTAssertTrue(file.isChanged(12...14))
        XCTAssertTrue(file.isChanged(28...32))
    }

    func test_codeNextToAChange_isNot() {
        XCTAssertFalse(file.isChanged(9...9))
        XCTAssertFalse(file.isChanged(13...13))
        XCTAssertFalse(file.isChanged(31...40))
    }

    // Lines removed after line 20, between 20 and 21: code on both sides of them lost some of its middle.
    func test_codeAroundRemovedLines_isChanged_butCodeOnOneSideIsNot() {
        XCTAssertTrue(file.isChanged(20...21))
        XCTAssertTrue(file.isChanged(15...25))
        XCTAssertFalse(file.isChanged(20...20))
        XCTAssertFalse(file.isChanged(21...22))
    }

    func test_aWholeNewFile_isAllChanged() {
        XCTAssertTrue(ChangedFile(path: "New.swift", sha256: "").isChanged(1...1))
    }

    func test_lines_encodeAsPairs() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let json = try String(lossyUTF8: encoder.encode(file))

        XCTAssertEqual(json, #"{"deletionsAfter":[20],"lines":[[10,12],[30,30]],"path":"A.swift","sha256":""}"#)
        XCTAssertEqual(try JSONDecoder().decode(ChangedFile.self, from: Data(json.utf8)), file)
    }

    func test_aWholeFile_leavesOutItsLines() throws {
        let json = try String(lossyUTF8: JSONEncoder().encode(ChangedFile(path: "New.swift", sha256: "ab")))

        XCTAssertFalse(json.contains("lines"))
        XCTAssertFalse(json.contains("deletionsAfter"))
    }
}
