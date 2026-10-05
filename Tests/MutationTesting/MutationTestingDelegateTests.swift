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
                "platform=macOS,arch=x86_64,variant=Mac Catalyst",
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
            "muter.xctestrun",
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

    // When SwiftMutator's own suite is the one being mutation tested, its tests run with the outer run's
    // active-mutant file named. A process started here must not read that file, or the outer run's mutant
    // would be switched on in it. Checked on the pure function, so this test never sets a variable the
    // outer run's generated code may read at any moment.
    func test_inheritedEnvironment_dropsAnOuterRunsActiveMutantFile() {
        let environment = MuterProcessFactory.environment(inheriting: [
            activeMutantFileKey: "/outer/.swiftmutator-active-mutant",
            isMuterRunningKey: isMuterRunningValue,
            "PATH": "/usr/bin",
        ])

        XCTAssertEqual(environment, ["PATH": "/usr/bin"])
    }

    // `swift test` relays its test runners' output through its own standard output, which holds output
    // bound for a file 4 KiB at a time until it exits. A run stopped at its first failed test would show
    // that failure late, or lose its whole log.
    func test_whenStoppingAtFirstFailure_thenEveryTestProcessWritesUnbuffered() async throws {
        current.process = { Self.makeProcess(inheritingUnbufferedOutput: nil) }
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            stopAtFirstFailure: true
        )
        let mutant = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        // The baseline too, although it is never stopped, so it runs as the mutants that stop do.
        for schemata in [mutant, .null] {
            let testProcess = try await sut.testProcess(
                with: configuration,
                schemata: schemata,
                and: FileHandle(fileDescriptor: 0)
            )

            XCTAssertEqual(testProcess.environment?["NSUnbufferedIO"], "YES", schemata.id)
        }
    }

    func test_whenNotStoppingAtFirstFailure_thenOutputBufferingIsLeftAlone() async throws {
        let configurations = [
            MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], stopAtFirstFailure: false),
            // Switched on, but xcodebuild runs can't be stopped.
            MuterConfiguration(executable: "/tmp/xcodebuild", arguments: ["test"], stopAtFirstFailure: true),
        ]
        let mutant = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        for inherited in [nil, "NO"] {
            current.process = { Self.makeProcess(inheritingUnbufferedOutput: inherited) }
            for configuration in configurations {
                for schemata in [mutant, .null] {
                    let testProcess = try await sut.testProcess(
                        with: configuration,
                        schemata: schemata,
                        and: FileHandle(fileDescriptor: 0)
                    )

                    XCTAssertEqual(
                        testProcess.environment?["NSUnbufferedIO"],
                        inherited,
                        "\(configuration.testCommandExecutable) \(schemata.id)"
                    )
                }
            }
        }
    }

    /// The real factory's process, as if this process's environment had `NSUnbufferedIO` set to `value`,
    /// so these tests don't depend on the environment the test suite was launched with.
    private static func makeProcess(inheritingUnbufferedOutput value: String?) -> MuterProcess {
        let process = MuterProcessFactory.makeProcess()
        process.environment?["NSUnbufferedIO"] = value
        return process
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
        try await assertTheTimeLimitComingFirstTimesTheRunOutAndKillsItOnce(stopAtFirstFailure: false)
    }

    // The run is also watched for a failed test, which never comes.
    func test_whenTheTimeLimitComesFirstWhileStoppingAtFirstFailure_thenTheRunTimesOutAndIsKilledOnce() async throws {
        try await assertTheTimeLimitComingFirstTimesTheRunOutAndKillsItOnce(stopAtFirstFailure: true)
    }

    private func assertTheTimeLimitComingFirstTimesTheRunOutAndKillsItOnce(
        stopAtFirstFailure: Bool?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let testProcess = ScriptedProcessSpy([.write("\(passedTestLine)\n", after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 0.3,
            stopAtFirstFailure: stopAtFirstFailure
        )

        let started = Date()
        let result = try await runMutantsTests(on: testProcess, using: configuration)

        XCTAssertEqual(result.outcome, .timeout, file: file, line: line)
        // Well under the process's own deadline, so the time limit, not that deadline, ended the run.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, file: file, line: line)
        // A second kill would come from a GCD thread, so it could land after the run returned.
        let deadline = Date().addingTimeInterval(0.2)
        while testProcess.terminateTreeCallCount <= 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1, file: file, line: line)
    }

    // MARK: - Stopping at the first failed test

    private let passedTestLine = "✔ Test passes() passed after 0.001 seconds."
    private let failedTestLine = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4"
    private let failedRunSummary = "✘ Test run with 2 tests in 1 suite failed after 0.301 seconds with 1 issue."
    private let stoppingConfiguration = MuterConfiguration(
        executable: "/tmp/swift",
        arguments: ["test"],
        testSuiteTimeOut: 60,
        stopAtFirstFailure: true
    )

    // Any failed test kills a mutant, so the tests after it can't change its outcome.
    func test_whenAMutantsRunShowsAFailedTest_thenItIsStoppedThereAndCountsAsKilled() async throws {
        let testProcess = ScriptedProcessSpy([.write("\(passedTestLine)\n\(failedTestLine)\n", after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let started = Date()
        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
        // Well under the process's own deadline, so the failed test, not that deadline, ended the run.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // A stopped run's log ends where it was killed, often partway through a line, with no summary. The note
    // says why, and which line stopped it, without its colour codes.
    func test_whenARunIsStoppedAtItsFirstFailure_thenItsLogEndsWithANoteNamingTheLine() async throws {
        let colouredFailedTestLine = "\u{1B}[91m✘\u{1B}[0m"
            + " Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4"
        let output = "\(passedTestLine)\n\(colouredFailedTestLine)\n↳ 5 == 4 → false\n✔ Test other() pass"
        let testProcess = ScriptedProcessSpy([.write(output, after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.testLog, output + """


            [SwiftMutator] Stopped this test run at its first failed test (stopAtFirstFailure); the tests after it did not run.
            [SwiftMutator] The line that stopped it: \(failedTestLine)

            """)
    }

    // A blank line sets the note apart, whether the run was killed after a whole line or partway through one.
    func test_theNoteForAStoppedRun_followsABlankLine() {
        for log in ["\(failedTestLine)\n", "\(failedTestLine)\n✔ Test other() pass"] {
            let notedLog = log + MutationTestingDelegate.noteForRunStopped(at: failedTestLine, after: log)

            XCTAssertTrue(notedLog.contains("\n\n[SwiftMutator] Stopped this test run"), notedLog)
        }
    }

    // Whether the baseline passes decides whether mutation testing can start, so it always runs to its end.
    func test_theBaselineIsNeverStoppedAtAFailedTest() async throws {
        for workingDirectory in [nil, outputFolderURL] {
            let testProcess = ScriptedProcessSpy([
                .write("\(failedTestLine)\n", after: 0),
                .write("\(failedRunSummary)\n", after: 0.3),
            ])
            current.process = { testProcess }

            let result: (outcome: TestSuiteOutcome, testLog: String)
            if let workingDirectory {
                result = await sut.benchmarkTests(
                    using: stoppingConfiguration,
                    savingResultsIntoFileNamed: "logFileName",
                    workingDirectory: workingDirectory
                )
            } else {
                result = await sut.benchmarkTests(
                    using: stoppingConfiguration,
                    savingResultsIntoFileNamed: "logFileName"
                )
            }

            let overload = workingDirectory == nil ? "in the project" : "in a worker's clone"
            XCTAssertEqual(testProcess.terminateTreeCallCount, 0, overload)
            XCTAssertTrue(result.testLog.contains(failedRunSummary), "\(overload): \(result.testLog)")
        }
    }

    func test_whenStopAtFirstFailureIsOff_thenAFailingRunGoesToTheEnd() async throws {
        let configurations = [
            MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 60, stopAtFirstFailure: false),
            // On by default, but a wrapper script counts as `swift test` only with `buildSystem: swift`.
            MuterConfiguration(executable: "/tmp/run-tests.sh", arguments: ["test"], testSuiteTimeOut: 60),
            // Switched on, but xcodebuild runs can't be stopped.
            MuterConfiguration(executable: "/tmp/xcodebuild", arguments: ["test"], testSuiteTimeOut: 60, stopAtFirstFailure: true),
        ]
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        for configuration in configurations {
            let testProcess = ScriptedProcessSpy([
                .write("\(failedTestLine)\n", after: 0),
                .write("\(failedRunSummary)\n", after: 0.3),
            ])

            let result = try await runMutantsTests(on: testProcess, using: configuration)

            let description = "\(configuration.testCommandExecutable), \(String(describing: configuration.stopAtFirstFailure))"
            XCTAssertEqual(testProcess.terminateTreeCallCount, 0, description)
            XCTAssertEqual(result.outcome, .failed, description)
            XCTAssertTrue(result.testLog.contains(failedRunSummary), "\(description): \(result.testLog)")
        }
    }

    // Only a failing issue kills a mutant: a known issue or a warning leaves its test passing.
    func test_knownIssuesAndWarnings_doNotStopTheRun() async throws {
        let testProcess = ScriptedProcessSpy([
            .write("""
                ━ Test knownIssue() recorded a known issue at ATests.swift:34:13: Expectation failed: 1 == 2
                ⚠︎ Test recordsWarning() recorded a warning at CTests.swift:35:21: Issue recorded
                \(passedTestLine)

                """, after: 0),
            .write("✔ Test run with 3 tests in 1 suite passed after 0.301 seconds with 1 known issue.\n", after: 0.3),
        ])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let started = Date()
        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
        // Well under the time limit and runMutantsTests' cancel: the run ends with its process, although the
        // follower was still watching the log.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the run outlived its process")
    }

    // The time limit can fire while a run is being stopped at its failed test. Its handler may not kill the
    // process again, and the run counts as stopped there, which kills the mutant, not as timed out.
    func test_whenTheTimeLimitFiresAfterTheRunWasStopped_thenItCountsAsKilledAndIsKilledOnce() async throws {
        testingTimeOutExecutor.firesAfterBody = true
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n", after: 0), .runUntilKilled])

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
    }

    // Foundation reaps a process up to about 60 ms before waitUntilExit() returns. A run whose last test
    // failed just before it exited was stopped in that gap: a process that had exited was killed, and its
    // whole log got a note saying the tests after the failure did not run.
    func test_whenTheLogShowsAFailedTestAfterTheProcessExited_thenTheRunIsNotStopped() async throws {
        // Written while the follower waits between reads, so it reads the line only after the exit.
        let testProcess = ScriptedProcessSpy(
            [.write("\(failedTestLine)\n\(failedRunSummary)\n", after: 0.05)],
            exitNoticedAfter: 0.5
        )
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
        XCTAssertFalse(result.testLog.contains("[SwiftMutator]"), result.testLog)
    }

    // In the same gap, a time limit that fired just after the process exited killed it, and reported a run
    // that passed as timed out.
    func test_whenTheTimeLimitFiresAfterTheProcessExitedButBeforeWaitingEnds_thenNothingIsKilled() async throws {
        let summary = "✔ Test run with 1 test in 1 suite passed after 0.001 seconds.\n"
        let testProcess = ScriptedProcessSpy([.write(summary, after: 0)], exitNoticedAfter: 0.5)
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 0.2)

        let result = try await runMutantsTests(on: testProcess, using: configuration)

        XCTAssertEqual(result.outcome, .passed, result.testLog)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
    }

    // A passing baseline printed a line shaped like a failed test, so a timed-out run showing it may only
    // have run the test that prints it.
    func test_whenFailedTestLinesAreUnreliable_thenATimedOutRunShowingOneTimesOut() async throws {
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n", after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 0.3,
            stopAtFirstFailure: true
        ).withUnreliableFailedTestLines()

        let result = try await runMutantsTests(on: testProcess, using: configuration)

        XCTAssertEqual(result.outcome, .timeout, result.testLog)
    }

    // MARK: - How a run ended

    func test_aRunThatEndsByItself_endsExited_withItsExitStatus() async throws {
        process.terminationStatus = 3

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .runtimeError)
        XCTAssertEqual(result.ending, .exited)
        XCTAssertEqual(result.exitStatus, process.terminationStatus)
    }

    // A run SwiftMutator stopped exits with the status of its SIGKILL, which says nothing about the mutant.
    func test_aRunStoppedAtItsTimeLimit_endsTimedOut_withoutExitStatus() async throws {
        testingTimeOutExecutor.shouldSucceed = false
        process.terminationStatus = SIGKILL

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertNil(result.exitStatus)
    }

    func test_aRunStoppedAtItsFirstFailedTest_endsStoppedAtFailedTest_withoutExitStatus() async throws {
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n", after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.ending, .stoppedAtFailedTest)
        XCTAssertEqual(testProcess.terminationStatus, SIGKILL)
        XCTAssertNil(result.exitStatus)
    }

    // Whoever cancels a run doesn't use its outcome, which stays a build error, and its ending says so. With a
    // time limit, the CancellationError can come from the time limit's task rather than from the run's ending.
    func test_aCancelledRun_endsCancelled_andIsStillABuildError() async throws {
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        for timeLimit in [nil, 60] as [TimeInterval?] {
            // Gives up after 5 seconds, so the run ends even if cancelling it doesn't kill its process.
            let testProcess = ScriptedProcessSpy([.runUntilKilled])
            current.process = { testProcess }
            let configuration = MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: timeLimit)

            let run = Task { [sut] in
                await sut.runTestSuite(
                    withSchemata: schemata,
                    using: configuration,
                    savingResultsIntoFileNamed: "logFileName"
                )
            }
            let deadline = Date().addingTimeInterval(5)
            while !testProcess.waitUntilExitCalled, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            run.cancel()
            let result = await run.value

            let description = "time limit: \(String(describing: timeLimit))"
            XCTAssertEqual(result.ending, .cancelled, description)
            XCTAssertEqual(result.outcome, .buildError, description)
            XCTAssertNil(result.exitStatus, description)
        }
    }

    func test_aCommandThatCannotStart_endsCouldNotRun_withTheSameMessage() async throws {
        process.runError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file \"swift\" doesn't exist."]
        )

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "swift", arguments: ["test", "--filter", "CalcTests"]),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .buildError)
        XCTAssertEqual(result.ending, .couldNotRun)
        XCTAssertNil(result.exitStatus)
        XCTAssertEqual(result.testLog, """
            SwiftMutator could not run your test command and captured no test output.

              executable: swift
              arguments: test --filter CalcTests
              working directory: \(outputFolder!)

            The file "swift" doesn't exist.
            """)
    }

    /// Runs a mutant's tests with `testProcess` as the test command. Cancels the run after 10 seconds, which
    /// kills its process, so a run that never ends, such as one still watching its log, fails a test instead
    /// of hanging it. Then waits at most 5 seconds more: a run that ignores its cancellation, such as one
    /// whose follower never stops, fails a test too.
    private func runMutantsTests(
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

    /// Returns once `count` of `processes` are being waited for, or after `timeout` seconds.
    private func waitUntil(_ count: Int, of processes: [ScriptedProcessSpy], areWaitedForWithin timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while processes.filter(\.waitUntilExitCalled).count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
