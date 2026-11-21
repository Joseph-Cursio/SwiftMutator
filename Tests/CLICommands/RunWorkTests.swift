import ArgumentParser
@testable import muterCore
import XCTest

/// `--project-folder`: a run command moves into it once, before the run starts, and refuses to run when it can't.
final class RunWorkTests: MuterTestCase {
    private let step = MutationStepSpy()
    private let folder = URL(fileURLWithPath: "/work/MyApp")

    override func setUp() {
        super.setUp()
        step.resultToReturn = .success([])
    }

    // Before the log folder is made, so it is beside the project, as the copy is, and before any step.
    func test_theRun_movesIntoTheProjectFolder_beforeItStarts() async throws {
        doubles.fileManager.currentDirectoryPathToReturn = folder.path
        var pwd: [String] = []
        step.whileRunning = { [doubles] in
            XCTAssertEqual(doubles.fileManager.changeCurrentDirectoryPath, ["/work/MyApp"])
        }

        try await RunWork.perform(with: .make(projectFolder: folder), steps: [step]) { pwd.append($0) }

        XCTAssertEqual(doubles.fileManager.methodCalls.first, "changeCurrentDirectoryPath(_:)")
        XCTAssertEqual(doubles.fileManager.changeCurrentDirectoryPath, ["/work/MyApp"])
        XCTAssertEqual(pwd, ["/work/MyApp"])
        let logFolder = try XCTUnwrap(doubles.fileManager.paths.first, "no log folder was made")
        XCTAssertTrue(logFolder.hasPrefix("/work/MyApp_muter_logs"), logFolder)
        XCTAssertEqual(step.methodCalls, ["run(with:)"])
    }

    func test_withoutAProjectFolder_theRunStaysInTheCurrentFolder() async throws {
        doubles.fileManager.currentDirectoryPathToReturn = folder.path
        var pwd: [String] = []

        try await RunWork.perform(with: .make(), steps: [step]) { pwd.append($0) }

        XCTAssertEqual(doubles.fileManager.changeCurrentDirectoryPath, [])
        XCTAssertEqual(pwd, [])
        XCTAssertEqual(step.methodCalls, ["run(with:)"])
    }

    // Such as a folder it may not open. Nothing is made and no step runs, and the message says what to check, without
    // the banner that asks for a bug report.
    func test_aProjectFolderItCannotMoveInto_isRefused_beforeAnythingRuns() async throws {
        doubles.fileManager.changeCurrentDirectoryPathToReturn = false
        var pwd: [String] = []

        do {
            try await RunWork.perform(with: .make(projectFolder: folder), steps: [step]) { pwd.append($0) }
            XCTFail("The run started outside the project folder.")
        } catch {
            XCTAssertEqual(error as? ProjectFolderRefused, ProjectFolderRefused(path: "/work/MyApp"))
            XCTAssertEqual(
                Run.message(showing: error),
                "SwiftMutator couldn't move into the project folder /work/MyApp, which --project-folder gives. Check "
                    + "that it exists and that you may open it."
            )
            XCTAssertEqual(ExitCode.exitStatus(afterRunFailedWith: error), .stoppedOnAnError)
        }
        XCTAssertEqual(doubles.fileManager.methodCalls, ["changeCurrentDirectoryPath(_:)"])
        XCTAssertEqual(pwd, [])
        XCTAssertEqual(step.methodCalls, [])
    }
}
