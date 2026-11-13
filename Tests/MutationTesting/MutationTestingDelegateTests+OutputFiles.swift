@testable import muterCore
import TestingExtensions
import XCTest

extension MutationTestingDelegateTests {
    func test_switchOn() async throws {
        let schemata = try MutationSchema.make()
        let testRun = XCTestRun()

        try await sut.switchOn(
            schemata: schemata,
            for: testRun,
            at: outputFolderURL
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputFolderURL.appendingPathComponent("muter.xctestrun").path
            )
        )
    }

    func test_fileHandle() throws {
        let handleAndLogFileUrl = try sut.fileHandle(
            for: "logFileName"
        )

        XCTAssertEqual(handleAndLogFileUrl.logFileUrl.lastPathComponent, "logFileName")
        XCTAssertNotNil(handleAndLogFileUrl.handle)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: outputFolderURL.appendingPathComponent("logFileName").path
            )
        )
    }

    // A run's output goes to the run's log folder, outside every worker's folder, which may not exist yet.
    func test_fileHandle_takesAnAbsolutePath_andMakesItsFolder() throws {
        let file = outputFolderURL.appendingPathComponent("logs/running/baseline run").path

        let opened = try sut.fileHandle(for: file)

        XCTAssertEqual(opened.logFileUrl.path, file)
        XCTAssertEqual(try Data(contentsOf: opened.logFileUrl), Data())
    }

    // Whatever records the run moves the file to the name its log is kept under, or discards it (`keepOutput`), so
    // each log is written once.
    func test_aRunsOutputFile_staysOnceItsLogIsReadBack() async throws {
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"])
        let file = outputFolderURL.appendingPathComponent("running/mutant.log").path

        _ = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: configuration,
            savingResultsIntoFileNamed: file
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }

    // Its output is all a stopped run leaves to say what it was doing.
    func test_aCancelledRunsOutputFile_stays() async throws {
        let testProcess = ScriptedProcessSpy([.runUntilKilled])
        current.process = { testProcess }
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"])
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))
        let file = outputFolderURL.appendingPathComponent("running/mutant.log").path

        let run = Task { [sut] in
            await sut.runTestSuite(withSchemata: schemata, using: configuration, savingResultsIntoFileNamed: file)
        }
        let deadline = Date().addingTimeInterval(5)
        while !testProcess.hasStarted, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        run.cancel()
        let result = await run.value

        XCTAssertEqual(result.ending, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    }

    func test_aRunThatCannotStart_leavesNoOutputFile() async throws {
        process.runError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        let file = outputFolderURL.appendingPathComponent("running/mutant.log").path

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "swift", arguments: ["test"]),
            savingResultsIntoFileNamed: file
        )

        XCTAssertEqual(result.ending, .couldNotRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    }

    // So that if SwiftMutator dies first, killed or crashed, the test process is killed too.
    func test_aTestProcessIsRecordedInTheMutatedProjectsLock_whileItRuns() async throws {
        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.ending, .exited)
        XCTAssertEqual(mutatedProjectLocker.testProcesses, ["started 0", "ended 0"])
    }

    func test_aTestProcessThatCannotStart_isNotRecorded() async throws {
        process.runError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        _ = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(mutatedProjectLocker.testProcesses, [])
    }
}
