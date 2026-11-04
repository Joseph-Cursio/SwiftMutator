@testable import muterCore
import XCTest

/// How the file a run wrote its output to is kept, under the name its log has in the run's log folder, or discarded:
/// moved within the volume, never copied, and never a folder or a symbolic link.
final class KeepOutputTests: MuterTestCase {
    private var outputFolder = ""
    private var outputFolderURL: URL { URL(fileURLWithPath: outputFolder) }

    private let sut = MutationTestingDelegate()

    override func setUpWithError() throws {
        try super.setUpWithError()

        outputFolder = try makeTemporaryDirectory()
        // Relative names are taken from the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = outputFolder
    }

    // A rename, so the kept log is the file the run wrote, not a copy of it.
    func test_keepOutput_movesTheRunsFileToTheKeptName() throws {
        let output = try writeOutput("running/mutant.log", "Executed 3 tests, with 1 failure")
        let kept = outputFolderURL.appendingPathComponent("mutant kept.log").path
        let inode = try inodeNumber(of: output)

        XCTAssertTrue(sut.keepOutput(at: output, as: kept))

        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertEqual(try String(contentsOfFile: kept, encoding: .utf8), "Executed 3 tests, with 1 failure")
        XCTAssertEqual(try inodeNumber(of: kept), inode)
    }

    // Whatever is at the output's name when it can't be opened isn't this run's output. Left there, it would be kept
    // as the run's log, in place of the explanation, which is then written from the text.
    func test_aRunWhoseOutputCannotBeOpened_leavesNoFileThere_soItsExplanationIsKept() async throws {
        let file = outputFolderURL.appendingPathComponent("running/mutant.log").path
        try FileManager.default.createDirectory(
            atPath: (file as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file,
            contents: Data("not this run's".utf8),
            attributes: [.posixPermissions: 0o444]
        ))

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "swift", arguments: ["test"]),
            savingResultsIntoFileNamed: file
        )

        XCTAssertEqual(result.ending, .couldNotRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
        XCTAssertFalse(sut.keepOutput(at: file, as: outputFolderURL.appendingPathComponent("mutant.log").path))
    }

    func test_keepOutput_replacesAFileAlreadyAtTheKeptName() throws {
        let output = try writeOutput("running/mutant.log", "this run's log")
        let kept = try writeOutput("mutant kept.log", "an earlier log")

        XCTAssertTrue(sut.keepOutput(at: output, as: kept))

        XCTAssertEqual(try String(contentsOfFile: kept, encoding: .utf8), "this run's log")
    }

    // Names relative to the current directory, as `runTestSuite` takes them, with no log folder.
    func test_keepOutput_takesNamesRelativeToTheCurrentDirectory() throws {
        _ = try writeOutput("mutant.log", "this run's log")

        XCTAssertTrue(sut.keepOutput(at: "mutant.log", as: "mutant kept.log"))

        let kept = outputFolderURL.appendingPathComponent("mutant kept.log").path
        XCTAssertEqual(try String(contentsOfFile: kept, encoding: .utf8), "this run's log")
    }

    func test_keepOutput_withNoKeptName_removesTheRunsFile() throws {
        let output = try writeOutput("running/mutant.log", "a kill's log")

        XCTAssertFalse(sut.keepOutput(at: output, as: nil))

        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    // The caller then writes the log from its text.
    func test_keepOutput_withNoFile_movesNothing() throws {
        let output = outputFolderURL.appendingPathComponent("running/mutant.log").path
        let kept = outputFolderURL.appendingPathComponent("mutant kept.log").path

        XCTAssertFalse(sut.keepOutput(at: output, as: kept))

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept))
    }

    // A move that fails leaves nothing behind where the run wrote, and the caller writes the log from its text.
    func test_keepOutput_whenTheMoveFails_removesTheRunsFile() throws {
        let output = try writeOutput("running/mutant.log", "this run's log")
        let kept = outputFolderURL.appendingPathComponent("no such folder/mutant kept.log").path

        XCTAssertFalse(sut.keepOutput(at: output, as: kept))

        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept))
    }

    // An empty name is the current directory, the mutated project during mutation testing.
    func test_keepOutput_neverMovesOrRemovesAFolder() throws {
        let folder = outputFolderURL.appendingPathComponent("running").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        XCTAssertFalse(sut.keepOutput(at: "", as: nil))
        XCTAssertFalse(sut.keepOutput(at: folder, as: nil))
        XCTAssertFalse(sut.keepOutput(at: folder, as: outputFolderURL.appendingPathComponent("kept").path))

        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder))
        XCTAssertTrue(isFolder.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFolder))
    }

    func test_keepOutput_neverMovesOrRemovesASymbolicLink() throws {
        let target = try writeOutput("elsewhere.txt", "someone else's file")
        let link = outputFolderURL.appendingPathComponent("running/mutant.log").path
        try FileManager.default.createDirectory(
            atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        XCTAssertFalse(sut.keepOutput(at: link, as: nil))

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "someone else's file")
    }

    /// Writes `contents` to `name` in the output folder, making its folder, and gives its path.
    private func writeOutput(_ name: String, _ contents: String) throws -> String {
        let url = outputFolderURL.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    private func inodeNumber(of path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? Int)
    }
}
