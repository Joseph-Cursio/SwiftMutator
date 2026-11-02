@testable import muterCore
import XCTest

final class FileOperationTests: XCTestCase {
    func test_createsALoggingDirectory() throws {
        let fileManagerSpy = FileManagerSpy()
        let timestamp = DateComponents(
            calendar: .init(identifier: .gregorian),
            year: 2019,
            month: 5,
            day: 10,
            hour: 2,
            minute: 42
        )
        let date = try XCTUnwrap(timestamp.date)

        let loggingDirectory = try createLoggingDirectory(
            forProjectAt: "~/some/path",
            fileManager: fileManagerSpy,
            locale: Locale(identifier: "en_US"),
            timestamp: { date }
        )

        XCTAssertEqual(loggingDirectory, "~/some/path_muter_logs/May 10, 2019 at 2:42 AM")
        XCTAssertEqual(fileManagerSpy.methodCalls, [
            "createDirectory(atPath:withIntermediateDirectories:attributes:)",
            "createDirectory(atPath:withIntermediateDirectories:attributes:)",
        ])
        // The run's folder is made alone, which fails if it is there, so a run never takes another's.
        XCTAssertEqual(fileManagerSpy.createsIntermediates, [true, false])
        XCTAssertEqual(fileManagerSpy.paths, [
            "~/some/path_muter_logs",
            "~/some/path_muter_logs/May 10, 2019 at 2:42 AM",
        ])
    }

    // A session resumed at once, or two runs, started in one minute: sharing a folder, the later run's kept logs would
    // replace the earlier one's.
    func test_runsStartedInOneMinute_getAFolderEach() throws {
        let project = try makeTemporaryDirectory() + "/App"
        let minute = Date(timeIntervalSince1970: 1_791_000_000)
        let create = {
            try createLoggingDirectory(
                forProjectAt: project,
                locale: Locale(identifier: "en_US"),
                timestamp: { minute }
            )
        }

        let first = try create()
        try Data("first run's log".utf8).write(to: URL(fileURLWithPath: "\(first)/baseline run.log"))
        let second = try create()
        let third = try create()

        let name = (first as NSString).lastPathComponent
        XCTAssertEqual(first, "\(project)_muter_logs/\(name)")
        XCTAssertEqual(second, "\(first) (2)")
        XCTAssertEqual(third, "\(first) (3)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: "\(project)_muter_logs").sorted(),
            [name, "\(name) (2)", "\(name) (3)"]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second), [])
        XCTAssertEqual(
            try String(contentsOfFile: "\(first)/baseline run.log", encoding: .utf8),
            "first run's log"
        )
    }

    // A file of the folder's name is skipped as a folder would be.
    func test_aFileOfTheFoldersName_isSkipped() throws {
        let project = try makeTemporaryDirectory() + "/App"
        let minute = Date(timeIntervalSince1970: 1_791_000_000)
        let create = {
            try createLoggingDirectory(
                forProjectAt: project,
                locale: Locale(identifier: "en_US"),
                timestamp: { minute }
            )
        }
        let first = try create()
        try FileManager.default.removeItem(atPath: first)
        try Data().write(to: URL(fileURLWithPath: first))

        XCTAssertEqual(try create(), "\(first) (2)")
    }

    // Logs go next to the project, like the `_mutated` copy, never inside it:
    // a `muter_logs` folder in the project is picked up by the next project
    // copy and shows up as untracked files in the user's repository.
    func test_loggingDirectoryIsASiblingOfTheProject() throws {
        let fileManagerSpy = FileManagerSpy()

        let loggingDirectory = try createLoggingDirectory(
            forProjectAt: "/Users/me/projects/App/",
            fileManager: fileManagerSpy,
            locale: Locale(identifier: "en_US"),
            timestamp: { Date(timeIntervalSince1970: 0) }
        )

        XCTAssertTrue(loggingDirectory.hasPrefix("/Users/me/projects/App_muter_logs/"), loggingDirectory)
        XCTAssertFalse(loggingDirectory.hasPrefix("/Users/me/projects/App/"), loggingDirectory)
    }
}
