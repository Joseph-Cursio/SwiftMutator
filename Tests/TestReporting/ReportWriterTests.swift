@testable import muterCore
import XCTest

final class ReportWriterTests: XCTestCase {
    private var directory = ""

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try makeTemporaryDirectory()
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

    func test_saysWhenItCannotSave() {
        let path = "\(directory)/missing/report.txt"

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
