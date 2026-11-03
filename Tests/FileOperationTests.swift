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

    // A run that kept nothing removes its folder at exit, so a run started in the same minute can fail to make the
    // folder and then find it gone. The name is free again: it is claimed, not skipped, and the run starts.
    func test_aFolderThatVanishes_isClaimedAgain() throws {
        let fileManagerSpy = FileManagerSpy()
        let exists = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        fileManagerSpy.createDirectoryErrorsToThrow = [nil, exists, nil]
        fileManagerSpy.fileExistsToReturn = [false]

        let loggingDirectory = try createLoggingDirectory(
            forProjectAt: "/Users/me/projects/App",
            fileManager: fileManagerSpy,
            locale: Locale(identifier: "en_US"),
            timestamp: { Date(timeIntervalSince1970: 0) }
        )

        let name = (loggingDirectory as NSString).lastPathComponent
        XCTAssertEqual(loggingDirectory, "/Users/me/projects/App_muter_logs/\(name)")
        XCTAssertFalse(name.hasSuffix(")"), name)
        XCTAssertEqual(fileManagerSpy.paths, ["/Users/me/projects/App_muter_logs", loggingDirectory, loggingDirectory])
        XCTAssertEqual(fileManagerSpy.fileExistsAtPath, [loggingDirectory])
    }

    // A folder that can't be made, and isn't there, is tried a few times; then the error ends the run.
    func test_aFolderThatCantBeMade_throwsAfterAFewTries() throws {
        let fileManagerSpy = FileManagerSpy()
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        fileManagerSpy.createDirectoryErrorsToThrow = [nil, denied, denied, denied, nil]

        XCTAssertThrowsError(
            try createLoggingDirectory(
                forProjectAt: "/Users/me/projects/App",
                fileManager: fileManagerSpy,
                locale: Locale(identifier: "en_US"),
                timestamp: { Date(timeIntervalSince1970: 0) }
            )
        ) { error in
            XCTAssertTrue("\(error)".contains("could not create its log folder"), "\(error)")
        }
        XCTAssertEqual(fileManagerSpy.paths.count, 4)
        XCTAssertEqual(Set(fileManagerSpy.paths.dropFirst()).count, 1)
    }

    // A run that kept nothing in its log folder leaves no folder.
    func test_removeFolderIfEmpty_removesAnEmptyFolder() throws {
        let folder = try makeTemporaryDirectory() + "/run"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)

        removeFolderIfEmpty(atPath: folder, fileManager: FileManager.default)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder))
    }

    // A kept log, or a file the user or Finder put there, keeps the folder and what is in it.
    func test_removeFolderIfEmpty_keepsAFolderWithAFile() throws {
        let root = try makeTemporaryDirectory()
        for file in ["baseline run.log", ".DS_Store"] {
            let folder = "\(root)/with \(file)"
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
            try Data("kept".utf8).write(to: URL(fileURLWithPath: "\(folder)/\(file)"))

            removeFolderIfEmpty(atPath: folder, fileManager: FileManager.default)

            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [file])
        }
    }

    func test_removeFolderIfEmpty_ignoresAMissingFolder() throws {
        let root = try makeTemporaryDirectory()

        removeFolderIfEmpty(atPath: root + "/missing", fileManager: FileManager.default)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
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
