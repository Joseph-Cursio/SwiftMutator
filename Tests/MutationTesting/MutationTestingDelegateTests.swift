@testable import muterCore
import TestingExtensions
import XCTest

final class MutationTestingDelegateTests: MuterTestCase {
    var outputFolder = ""
    var outputFolderURL: URL { URL(fileURLWithPath: outputFolder) }

    let sut = MutationTestingDelegate()

    override func setUpWithError() throws {
        try super.setUpWithError()

        outputFolder = try makeTemporaryDirectory()
        // Test logs are written to the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = outputFolder
    }

    func test_testProcessForXcodeBuild() async throws {
        current.process = { MuterProcessFactory.makeProcess() }

        let configuration = MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: [
                "-destination",
                "platform=macOS,arch=x86_64,variant=Mac Catalyst",
            ]
        )

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let testProcess = try sut.testProcess(
            with: configuration,
            schemata: schemata,
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(testProcess.arguments, [
            "test-without-building",
            "-destination",
            "platform=macOS,arch=x86_64,variant=Mac Catalyst",
            "-xctestrun",
            "muter.xctestrun",
        ])

        XCTAssertEqual(testProcess.executableURL?.path, "/tmp/xcodebuild")
    }

    // Each mutant's run starts with an empty derived data folder of its worker's, where xcodebuild writes its result
    // bundle and logs.
    func test_testProcessForXcodeBuild_emptiesTheWorkersDerivedDataBeforeAMutantsRun() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )
        .forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        ))

        let testProcess = try sut.testProcess(
            with: configuration,
            schemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(fileManager.paths, ["/path/App_mutated.DerivedData"])
        XCTAssertEqual(testProcess.arguments, [
            "test-without-building",
            "-destination",
            "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun",
            "muter.xctestrun",
            "-derivedDataPath",
            "/path/App_mutated.DerivedData",
            "-collect-test-diagnostics",
            "never",
        ])
    }

    // The baseline builds, with the test command as it is, so its derived data is the user's.
    func test_testProcessForXcodeBuild_leavesTheWorkersDerivedDataAloneForTheBaseline() async throws {
        current.process = { MuterProcessFactory.makeProcess() }
        let configuration = MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"]
        )
        .forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        ))

        let baselineProcess = try sut.testProcess(
            with: configuration,
            schemata: .null,
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(fileManager.paths, [])
        XCTAssertEqual(baselineProcess.arguments, ["-destination", "platform=macOS", "test"])
    }

    func test_testProcessForSwiftBuild() async throws {
        current.process = { MuterProcessFactory.makeProcess() }

        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"]
        )

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let testProcess = try sut.testProcess(
            with: configuration,
            schemata: schemata,
            and: FileHandle(fileDescriptor: 0)
        )

        // SwiftPM keys its cache of compiled package manifests on the whole environment, so the mutant is
        // named in a file the environment names, rather than in a variable of its own.
        let activeMutantFile = "\(outputFolder)\(activeMutantFileSuffix)"
        XCTAssertNil(testProcess.environment?[schemata.id])
        XCTAssertNil(testProcess.environment?["SIMCTL_CHILD_\(schemata.id)"])
        XCTAssertEqual(testProcess.environment?[activeMutantFileKey], activeMutantFile)
        XCTAssertEqual(writeFile.contentPassed?.components(separatedBy: "\n").first, schemata.id)
        XCTAssertEqual(writeFile.pathPassed, activeMutantFile)
        XCTAssertEqual(testProcess.environment?[isMuterRunningKey], isMuterRunningValue)
        XCTAssertEqual(testProcess.arguments, ["test", "--skip-build", "--quiet"])
        XCTAssertEqual(testProcess.executableURL?.path, "/tmp/swift")
    }

    // MARK: - Switching a mutant on

    /// Ends the name of the file beside a worker's folder that names the mutant a `swift test` run switches on.
    let activeMutantFileSuffix = ".active-mutant"

    // MARK: - Stopping at the first failed test

    let passedTestLine = "✔ Test passes() passed after 0.001 seconds."
    let failedTestLine = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4"
    let failedRunSummary = "✘ Test run with 2 tests in 1 suite failed after 0.301 seconds with 1 issue."
    let stoppingConfiguration = MuterConfiguration(
        executable: "/tmp/swift",
        arguments: ["test"],
        testSuiteTimeOut: 60,
        stopAtFirstFailure: true
    )

    /// Runs a mutant's tests with `testProcess` as the test command. Cancels the run after 10 seconds, which
    /// kills its process, so a run that never ends, such as one still watching its log, fails a test instead
    /// of hanging it. Then waits at most 5 seconds more: a run that ignores its cancellation, such as one
    /// whose follower never stops, fails a test too.
    func runMutantsTests(
        on testProcess: ScriptedProcessSpy,
        using configuration: MuterConfiguration
    ) async throws -> TestRun {
        current.process = { testProcess }
        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let ended = XCTestExpectation(description: "the run ended")
        let run = Task { [sut] in
            let result = await sut.runTestSuite(
                withSchemata: schemata,
                using: configuration,
                savingResultsIntoFileNamed: "logFileName"
            )
            ended.fulfill()
            return result
        }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            run.cancel()
        }
        defer { deadline.cancel() }
        guard await XCTWaiter().fulfillment(of: [ended], timeout: 15) == .completed else {
            return try XCTUnwrap(nil, "the run ignored its cancellation")
        }
        return await run.value
    }
}
