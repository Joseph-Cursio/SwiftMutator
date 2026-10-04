@testable import muterCore
import TestingExtensions
import XCTest

final class MutationTestingDelegateTests: MuterTestCase {
    private var outputFolder: String!
    private var outputFolderURL: URL { URL(fileURLWithPath: outputFolder) }

    private let sut = MutationTestingDelegate()

    override func setUpWithError() throws {
        try super.setUpWithError()

        outputFolder = try makeTemporaryDirectory()
        // Test logs are written to the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = outputFolder
    }

    func test_testProcessForXcodeBuild() async throws {
        current.process = MuterProcessFactory.makeProcess

        let configuration = MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: [
                "-destination",
                "platform=macOS,arch=x86_64,variant=Mac Catalyst"
            ]
        )

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let testProcess = try await sut.testProcess(
            with: configuration,
            schemata: schemata,
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(testProcess.arguments, [
            "test-without-building",
            "-destination",
            "platform=macOS,arch=x86_64,variant=Mac Catalyst",
            "-xctestrun",
            "muter.xctestrun"
        ])

        XCTAssertEqual(testProcess.executableURL?.path, "/tmp/xcodebuild")
    }

    func test_testProcessForSwiftBuild() async throws {
        current.process = MuterProcessFactory.makeProcess

        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"]
        )

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let testProcess = try await sut.testProcess(
            with: configuration,
            schemata: schemata,
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(testProcess.environment?[schemata.id], "YES")
        // Also forwarded with the SIMCTL_CHILD_ prefix so it reaches an iOS Simulator test host
        // (CoreSimulator only propagates SIMCTL_CHILD_-prefixed vars into the simulated process).
        XCTAssertEqual(testProcess.environment?["SIMCTL_CHILD_\(schemata.id)"], "YES")
        XCTAssertEqual(testProcess.environment?[isMuterRunningKey], isMuterRunningValue)
        XCTAssertEqual(testProcess.arguments, ["test", "--skip-build"])
        XCTAssertEqual(testProcess.executableURL?.path, "/tmp/swift")
    }

    func test_makeProcess_doesNotSetMuterRunningMarker() {
        // The shared factory (used for build-for-testing too) must NOT carry IS_MUTER_RUNNING — on
        // some projects it makes xcodebuild skip writing build-request.json, breaking BuildForTesting.
        // The marker belongs only on the test process (asserted in test_testProcessForSwiftBuild).
        let process = MuterProcessFactory.makeProcess()

        XCTAssertNil(process.environment?[isMuterRunningKey])
    }

    func test_makeProcess_dropsAnInheritedMuterRunningMarker() {
        // SwiftMutator sets the marker on the test process, so when its own suite is the one being
        // mutation tested, this process already has it.
        let previous = ProcessInfo.processInfo.environment[isMuterRunningKey]
        setenv(isMuterRunningKey, isMuterRunningValue, 1)
        defer {
            if let previous {
                setenv(isMuterRunningKey, previous, 1)
            } else {
                unsetenv(isMuterRunningKey)
            }
        }

        let process = MuterProcessFactory.makeProcess()

        XCTAssertNil(process.environment?[isMuterRunningKey])
    }

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

    func test_timeout() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 9
        )

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        _ = await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertTrue(testingTimeOutExecutor.withTimeLimitCalled)
        XCTAssertEqual(testingTimeOutExecutor.timeLimitPassed, 9)
    }

    func test_whenTestTimesOut_thenKillsProcessTreeAndReportsTimeout() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 9
        )
        // Force the timeout branch (the test "ran too long").
        testingTimeOutExecutor.shouldSucceed = false

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let result = await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        // On timeout we kill the WHOLE process tree (not just interrupt the parent), and the mutant
        // is reported as timed out rather than hanging the run forever.
        XCTAssertTrue(process.terminateTreeCalled)
        XCTAssertEqual(result.outcome, .timeout)
    }

    func test_whenTestProcessCannotBeLaunched_thenTheFailureIsReportedAsTheLog() async throws {
        let configuration = MuterConfiguration(
            executable: "swift",
            arguments: ["test", "--filter", "CalcTests"]
        )
        process.runError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file \"swift\" doesn't exist."]
        )

        let result = await sut.benchmarkTests(
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        // A process that never launches produces no test output, so the spawn failure itself is the only
        // evidence there is. An empty log here leaves the abort message with nothing to show the user.
        XCTAssertEqual(result.outcome, .buildError)
        XCTAssertTrue(result.testLog.contains("swift"), result.testLog)
        XCTAssertTrue(result.testLog.contains("test --filter CalcTests"), result.testLog)
        XCTAssertTrue(result.testLog.contains("doesn't exist"), result.testLog)
        XCTAssertTrue(result.testLog.contains("working directory: \(outputFolder!)"), result.testLog)
    }

    // A parallel worker's clone is built by this run, so it must not skip the build, must run in the
    // clone, and has no time limit, like the baseline.
    func test_benchmarkingInAWorkingDirectory_runsTheWholeTestCommandThereWithoutATimeLimit() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 5
        )
        let clone = URL(fileURLWithPath: "/project_mutated_worker1")

        _ = await sut.benchmarkTests(
            using: configuration,
            savingResultsIntoFileNamed: "logFileName",
            workingDirectory: clone
        )

        XCTAssertEqual(process.arguments, ["test"])
        XCTAssertEqual(process.currentDirectoryURL, clone)
        XCTAssertFalse(testingTimeOutExecutor.withTimeLimitCalled)
    }

    func test_whenConfigurationHasNoTimeOut_thenRunTestsWithoutTimeOut() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: nil
        )

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        _ = await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertFalse(testingTimeOutExecutor.withTimeLimitCalled)
    }

    func test_whenTheLogEndsPartwayThroughACharacter_thenTheRunIsClassifiedFromIt() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"]
        )
        // A run stopped at the time limit, or a test process that crashed mid-write, can leave a log
        // that ends partway through a multi-byte character: here the first two of the three bytes of
        // "✔". Such a log couldn't be decoded, and the run was reported as a build error.
        let summary = "Executed 1 test, with 1 failure (0 unexpected) in 0.001 (0.001) seconds\n"
        process.outputWrittenBeforeExit = Data(summary.utf8) + [0xE2, 0x9C]

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let result = await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.testLog.contains("with 1 failure"), result.testLog)
    }

    // A run waited for its test process on the Swift concurrency thread it ran on. There are only about
    // as many of those as the machine has cores, so runs waiting together could hold every one, and then
    // nothing else could run until a process exited, not even a run's time limit. Synchronous, so the
    // test itself doesn't need one of those threads.
    func test_waitingForTestProcesses_holdsNoSwiftConcurrencyThread() throws {
        try assertWaitingForTestProcessesHoldsNoSwiftConcurrencyThread(timeLimit: 60)
    }

    func test_waitingForTestProcessesWithoutATimeLimit_holdsNoSwiftConcurrencyThread() throws {
        try assertWaitingForTestProcessesHoldsNoSwiftConcurrencyThread(timeLimit: nil)
    }

    /// Starts more runs than Swift concurrency has threads, each of a process that runs until it's killed,
    /// and checks that a task started after them still runs. Then kills every process and waits for
    /// every run to end.
    private func assertWaitingForTestProcessesHoldsNoSwiftConcurrencyThread(timeLimit: TimeInterval?) throws {
        let threadCount = ProcessInfo.processInfo.activeProcessorCount
        // They run well past the probe's time limit: one that gave up first would free its thread.
        let processes = (0..<threadCount + 2).map { _ in ScriptedProcessSpy([.runUntilKilled], deadline: 20) }
        let lock = NSLock()
        var unlaunched = processes[...]
        current.process = { lock.withLock { unlaunched.removeFirst() } }
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: timeLimit
        )
        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let runsEnded = processes.indices.map { index in
            let runEnded = expectation(description: "run \(index) ended")
            Task {
                _ = await sut.runTestSuite(
                    withSchemata: schemata,
                    using: configuration,
                    savingResultsIntoFileNamed: "logFileName\(index)"
                )
                runEnded.fulfill()
            }
            return runEnded
        }
        // Each run waits once its process is launched; if waiting holds a thread, these hold every one.
        waitUntil(threadCount, of: processes, areWaitedForWithin: 5)

        let probe = expectation(description: "a task started after the runs ran")
        Task { probe.fulfill() }
        wait(for: [probe], timeout: 5)

        processes.forEach { $0.terminateTree() }
        wait(for: runsEnded, timeout: 5)
    }

    // A run's task is cancelled when mutation testing stops with runs in flight, as it does after too many
    // build errors in a row. Waiting for the process ignores cancellation, so the run went on until its
    // tests ended, holding up the stop, and its processes ran on although nothing would read the outcome.
    func test_whenTheRunIsCancelled_thenItsProcessTreeIsKilled() throws {
        try assertCancellingARunKillsItsProcessTree(timeLimit: nil)
    }

    func test_whenARunWithATimeLimitIsCancelled_thenItsProcessTreeIsKilled() throws {
        try assertCancellingARunKillsItsProcessTree(timeLimit: 60)
    }

    /// Starts a run of a process that runs until it's killed, cancels the run's task once the process is
    /// waited for, and checks that the run kills it, once, and ends soon after.
    private func assertCancellingARunKillsItsProcessTree(
        timeLimit: TimeInterval?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let testProcess = ScriptedProcessSpy([.runUntilKilled])
        current.process = { testProcess }
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: timeLimit
        )
        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let runEnded = expectation(description: "the run ended")
        let run = Task {
            _ = await sut.runTestSuite(
                withSchemata: schemata,
                using: configuration,
                savingResultsIntoFileNamed: "logFileName"
            )
            runEnded.fulfill()
        }
        waitUntil(1, of: [testProcess], areWaitedForWithin: 5)
        let cancelled = Date()
        run.cancel()
        // Longer than the process's own deadline, so a run that isn't stopped still ends within it.
        wait(for: [runEnded], timeout: 10)

        XCTAssertEqual(testProcess.terminateTreeCallCount, 1, file: file, line: line)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 3, file: file, line: line)
    }

    // withTimeLimit returns whichever of its tasks finishes first, and the time limit can fire just as the
    // process exits. Its handler then killed a process that had exited, whose ID the system may have given
    // to another process, and reported a run that passed as timed out.
    func test_whenTheTimeLimitFiresAfterTheProcessExited_thenNothingIsKilled() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 9
        )
        testingTimeOutExecutor.firesAfterBody = true
        let summary = "Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds\n"
        process.outputWrittenBeforeExit = Data(summary.utf8)

        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let result = await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertFalse(process.terminateTreeCalled)
        XCTAssertEqual(result.outcome, .passed)
    }

    // When the time limit comes first, its handler kills the process tree, and then withTimeLimit cancels
    // the run's task, which is still waiting for the process. Cancelling it may not kill the tree again:
    // by then the process may have exited, and the system may have given its ID to another process.
    func test_whenTheTimeLimitComesFirst_thenTheRunTimesOutAndIsKilledOnce() async throws {
        let testProcess = ScriptedProcessSpy([.runUntilKilled])
        current.process = { testProcess }
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 0.3
        )
        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        let started = Date()
        let result = await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .timeout)
        // Well under the process's own deadline, so the time limit, not that deadline, ended the run.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        // A second kill would come from a GCD thread, so it could land after the run returned.
        let deadline = Date().addingTimeInterval(0.2)
        while testProcess.terminateTreeCallCount <= 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
    }

    /// Returns once `count` of `processes` are being waited for, or after `timeout` seconds.
    private func waitUntil(_ count: Int, of processes: [ScriptedProcessSpy], areWaitedForWithin timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while processes.filter(\.waitUntilExitCalled).count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
