@testable import muterCore
import XCTest

final class ReportWriterTests: XCTestCase {
    private let directory = XCTestCase.unusedTemporaryPath()

    override func setUpWithError() throws {
        try super.setUpWithError()

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    func test_savesTheReport() throws {
        let path = "\(directory)/report.txt"

        XCTAssertTrue(ReportWriter.save("the report", to: path, using: FileManager.default))

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "the report")
    }

    func test_replacesAnExistingReport() throws {
        let path = "\(directory)/report.txt"
        try "an older, longer report".write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertTrue(ReportWriter.save("the report", to: path, using: FileManager.default))

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "the report")
    }

    // The plain report is coloured whenever standard output is a terminal, even when it goes to a file.
    func test_savesTheReportWithoutColourCodes() throws {
        let path = "\(directory)/report.txt"
        let coloured = "Mutation Score of Test Suite: \u{1B}[1m\u{1B}[0m\u{1B}[32m80%\u{1B}[0m\n"
            + "\u{1B}[31mfailed\u{1B}[0m"

        XCTAssertTrue(ReportWriter.save(coloured, to: path, using: FileManager.default))

        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8),
            "Mutation Score of Test Suite: 80%\nfailed"
        )
    }

    // A CI job names out/report.sarif without making out: without the folder, a run would pass with no report.
    func test_makesTheFoldersOnTheWayToTheReport() throws {
        let path = "\(directory)/out/reports/report.txt"

        XCTAssertTrue(ReportWriter.save("the report", to: path, using: FileManager.default))

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "the report")
    }

    // No folder can be made where a file is.
    func test_saysWhenItCannotSave() {
        XCTAssertTrue(FileManager.default.createFile(atPath: "\(directory)/notAFolder", contents: nil))
        let path = "\(directory)/notAFolder/report.txt"

        XCTAssertFalse(ReportWriter.save("the report", to: path, using: FileManager.default))

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // A run without `-o` has no path to save to: it prints its report instead.
    func test_anEmptyPath_savesNothing() {
        let fileManager = FileManagerSpy()

        XCTAssertFalse(ReportWriter.save("the report", to: "", using: fileManager))

        XCTAssertEqual(fileManager.methodCalls, [])
    }
}
