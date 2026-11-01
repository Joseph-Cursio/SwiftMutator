@testable import muterCore
import XCTest

final class GitDiffParsingTests: XCTestCase {
    func test_entries_readEachStatus_andARenamesTwoPaths() {
        let output = [
            "M", "Sources/A.swift",
            "A", "Sources/New File.swift",
            "D", "Sources/Gone.swift",
            "R087", "Sources/Old.swift", "Sources/Moved.swift",
            "C100", "Sources/Copied.swift", "Sources/Copy.swift",
            "T", "Sources/Link.swift",
            "U", "Sources/Conflict.swift",
        ].joined(separator: "\0") + "\0"

        XCTAssertEqual(GitDiffParsing.entries(ofNameStatus: output), [
            .init(status: .modified, path: "Sources/A.swift"),
            .init(status: .added, path: "Sources/New File.swift"),
            .init(status: .deleted, path: "Sources/Gone.swift"),
            .init(status: .renamed(from: "Sources/Old.swift"), path: "Sources/Moved.swift"),
            .init(status: .added, path: "Sources/Copy.swift"),
            .init(status: .replaced, path: "Sources/Link.swift"),
            .init(status: .replaced, path: "Sources/Conflict.swift"),
        ])
    }

    func test_entries_ofNothing_areNone() {
        XCTAssertEqual(GitDiffParsing.entries(ofNameStatus: ""), [])
    }

    // An unknown status's paths can't be told from the next entry's status, so reading stops there.
    func test_entries_stopAtAnUnknownStatus() {
        let output = ["M", "A.swift", "X", "B.swift", "M", "C.swift"].joined(separator: "\0") + "\0"

        XCTAssertEqual(GitDiffParsing.entries(ofNameStatus: output), [.init(status: .modified, path: "A.swift")])
    }

    func test_hunks_giveAddedOrChangedLines_andWhereLinesWereOnlyRemoved() {
        let output = """
        diff --git a/A.swift b/A.swift
        index 1111111..2222222 100644
        --- a/A.swift
        +++ b/A.swift
        @@ -3 +3 @@ func a() {
        -    old()
        +    new()
        @@ -10,2 +9,0 @@ func b() {
        -    gone()
        -    gone()
        @@ -20,0 +18,3 @@
        +    one()
        +    two()
        +    three()
        @@ -1,2 +0,0 @@
        """

        let hunks = GitDiffParsing.hunks(ofUnifiedDiff: output)

        XCTAssertEqual(hunks.lines, [LineRange(first: 3, last: 3), LineRange(first: 18, last: 20)])
        XCTAssertEqual(hunks.deletionsAfter, [9, 0])
    }

    // A file with CRLF line endings: each line of code ends in a carriage return, the headers don't.
    func test_hunks_ofAFileWithCarriageReturns_areAllRead() {
        let output = "--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-a\r\n+A\r\n@@ -6 +6 @@ e\n-f\r\n+F\r\n"
            + "@@ -9 +8,0 @@\n-i\r\n"

        let hunks = GitDiffParsing.hunks(ofUnifiedDiff: output)

        XCTAssertEqual(hunks.lines, [LineRange(first: 1, last: 1), LineRange(first: 6, last: 6)])
        XCTAssertEqual(hunks.deletionsAfter, [8])
    }

    // Removed and added lines start with - and +, so a line of code that looks like a header isn't read as one.
    func test_hunks_ignoreCodeThatLooksLikeAHeader() {
        let output = """
        @@ -1 +1 @@
        -let a = "@@ -5 +5 @@"
        +let a = "@@ -7 +7,2 @@"
        """

        XCTAssertEqual(GitDiffParsing.hunks(ofUnifiedDiff: output).lines, [LineRange(first: 1, last: 1)])
    }
}

final class ChangedFileTests: XCTestCase {
    private let file = ChangedFile(
        path: "A.swift",
        lines: [LineRange(first: 10, last: 12), LineRange(first: 30, last: 30)],
        deletionsAfter: [20],
        sha256: ""
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

        let json = try String(decoding: encoder.encode(file), as: UTF8.self)

        XCTAssertEqual(json, #"{"deletionsAfter":[20],"lines":[[10,12],[30,30]],"path":"A.swift","sha256":""}"#)
        XCTAssertEqual(try JSONDecoder().decode(ChangedFile.self, from: Data(json.utf8)), file)
    }

    func test_aWholeFile_leavesOutItsLines() throws {
        let json = try String(decoding: JSONEncoder().encode(ChangedFile(path: "New.swift", sha256: "ab")), as: UTF8.self)

        XCTAssertFalse(json.contains("lines"))
        XCTAssertFalse(json.contains("deletionsAfter"))
    }
}
