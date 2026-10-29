import Foundation

// A pure-Swift async injection seam (an I/O *dependency*), not an Objective-C delegate, so the
// `class_delegate_protocol` expectation of a `class`/`@objc`-based protocol does not apply here.
// swiftlint:disable:next class_delegate_protocol
protocol MutationTestingIODelegate {
    /// Runs the test command with `schemata` switched on. Its output goes to `fileName`, a path relative to the
    /// current directory or an absolute one, whose folder is made if need be. The file is removed once its log has
    /// been read back, so only a run stopped before that leaves it.
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun

    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)` with the test command run in
    /// `workingDirectory`, a parallel worker's clone of the mutated project. A relative `fileName` is still taken
    /// from the current directory, not `workingDirectory`.
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun

    /// A baseline: the whole test command, build included, with no mutant switched on and no time limit. `fileName` is
    /// as in `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    )

    /// `benchmarkTests(using:savingResultsIntoFileNamed:)` with the test command, build included, run
    /// in `workingDirectory`, a parallel worker's clone of the mutated project. A relative `fileName` is still taken
    /// from the current directory, not `workingDirectory`.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    )

    /// A mutant's test command, which skips the build, with no mutant switched on, once the baseline has built the
    /// project: what a mutant's run costs. Like the baseline, it has no time limit and runs to its end. `fileName` is
    /// as in `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    )

    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL
    ) async throws
}

struct MutationTestingDelegate: MutationTestingIODelegate {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.mutatedProjectLocker)
    private var mutatedProjectLocker: MutatedProjectLocking
    @Dependency(\.process)
    private var process: ProcessFactory
    @Dependency(\.sleep)
    private var sleep: Sleep
    @Dependency(\.testingTimeOutExecutor)
    private var testingTimeOutExecutor: TestingTimeoutExecutorFactory
    @Dependency(\.writeFile)
    private var writeFile: WriteFile

    private let muterTestRunFileName = "muter.xctestrun"
    /// Ends the name of the file `activeMutantFileKey` names, beside a worker's folder.
    static let activeMutantFileSuffix = ".active-mutant"

    /// The file `activeMutantFileKey` names for a worker's folder, the mutated project or a clone:
    /// `<folder>.active-mutant`, beside it. Never in it: the folder is a whole copy of the project, `.git` included,
    /// so a test that lists the package's hidden files, or needs a clean `git status`, would see it. Its path is the
    /// same for every run of the worker, as one environment for them all needs, and for every SwiftMutator run.
    static func activeMutantFile(forWorkerIn folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + activeMutantFileSuffix)
    }

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        let run = await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true
        )
        return (run.outcome, run.testLog)
    }

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        let run = await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true,
            workingDirectory: workingDirectory
        )
        return (run.outcome, run.testLog)
    }

    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        let run = await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true,
            skippingBuild: true
        )
        return (run.outcome, run.testLog)
    }

    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun {
        await runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: false
        )
    }

    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun {
        await runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: false,
            workingDirectory: workingDirectory
        )
    }

    private func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        isBenchmark: Bool,
        skippingBuild: Bool? = nil,
        workingDirectory: URL? = nil
    ) async -> TestRun {
        var openedLogUrl: URL?
        do {
            let (testProcessFileHandle, testLogUrl) = try fileHandle(for: fileName)
            openedLogUrl = testLogUrl
            defer { try? testProcessFileHandle.close() }

            let process = try await testProcess(
                with: configuration,
                schemata: schemata,
                and: testProcessFileHandle,
                workingDirectory: workingDirectory,
                skippingBuild: skippingBuild
            )

            let timeout = isBenchmark ? nil : configuration.testSuiteTimeout
            // Never a baseline, the mutated project's or a worker's: whether it passes decides whether mutation
            // testing can start, so it always runs to its end. A run with no mutant switched on is one too.
            let stopsAtFirstFailure = !isBenchmark && schemata != .null && configuration.stopsAtFirstFailure
            return try await runTestProcess(
                process,
                logFileUrl: testLogUrl,
                withTimeout: timeout,
                stoppingAtFirstFailure: stopsAtFirstFailure,
                failedTestLinesAreReliable: configuration.failedTestLinesAreReliable
            )

        } catch {
            // Reaching here means the test command never ran — the log file couldn't be opened, or
            // the process failed to spawn. There is no test output to report, so the thrown error is
            // the only evidence of what went wrong; return it as the log rather than an empty string,
            // which leaves the caller with nothing to show the user. A cancelled run ends here too, by the
            // CancellationError of its ending or of its time limit's task. Its outcome then says nothing
            // about the mutant, and its ending says so.
            let ending: TestRun.Ending = error is CancellationError || Task.isCancelled ? .cancelled : .couldNotRun
            // A stopped run's output stays, to show what the run was doing; a run that never started has none.
            if ending == .couldNotRun, let openedLogUrl {
                try? FileManager.default.removeItem(at: openedLogUrl)
            }
            return TestRun(
                outcome: .buildError,
                testLog: """
                SwiftMutator could not run your test command and captured no test output.

                  executable: \(configuration.testCommandExecutable)
                  arguments: \(configuration.testCommandArguments.joined(separator: " "))
                  working directory: \(fileManager.currentDirectoryPath)

                \(error.localizedDescription)
                """,
                ending: ending
            )
        }
    }

    private func runTestProcess(
        _ process: Process,
        logFileUrl: URL,
        withTimeout timeout: TimeInterval?,
        stoppingAtFirstFailure: Bool,
        failedTestLinesAreReliable: Bool
    ) async throws -> TestRun {
        let ending = TestRunEnding()
        let follower = stoppingAtFirstFailure ? TestLogFollower(logFileUrl: logFileUrl) : nil
        let locker = mutatedProjectLocker
        let run: @Sendable () async throws -> TestingExecutionResult = {
            try await Self.runToExit(process, follower: follower, ending: ending, recordingIn: locker)
            return .success
        }
        if let timeout {
            _ = try await testingTimeOutExecutor().withTimeLimit(timeout, run) {
                // Kill the whole process tree, not just the launched command — see terminateTree(). Only if
                // nothing ended the run first: its process may have just exited, or been stopped at a failed test.
                if ending.recordTimeLimit(of: process) { process.terminateTree() }
                return .timeout
            }
        } else {
            _ = try await run()
        }

        // A signal from outside SwiftMutator (killall, logout, a supervisor stopping the whole tree) can end the test
        // command milliseconds before SwiftMutator's own signal stops mutation testing; the run would be recorded first,
        // as a crash, which counts as killed. Only a run that seems to have died of such a signal waits: SwiftMutator's
        // own kills end a run for another reason. A cancellation in the wait throws, and the run reads as cancelled.
        if ending.reason == .exited, Self.mayHaveEndedByAnOutsideSignal(process) {
            try await sleep(Self.outsideSignalWait)
        }

        // withTimeLimit returns whichever of its tasks finishes first, which needn't be what ended the run.
        let executionResult = try ending.executionResult()
        // Decoded leniently: the log is whatever the test command wrote, and a run stopped at the time
        // limit, or a test process that crashed mid-write, can end partway through a character. Strict
        // decoding threw on that, and the run was reported as a build error, outside the score.
        var testExecutionLog = try String(decoding: Data(contentsOf: logFileUrl), as: UTF8.self)
        // Read back, the log is the run's: whatever records the run keeps a copy of it, in the run's log folder.
        try? FileManager.default.removeItem(at: logFileUrl)
        let testResult = TestSuiteOutcome.from(
            testLog: testExecutionLog,
            terminationStatus: process.terminationStatus,
            timeoutExecution: executionResult,
            failedTestLinesAreReliable: failedTestLinesAreReliable
        )
        if case let .failedTest(line) = ending.reason {
            testExecutionLog += Self.noteForRunStopped(at: line, after: testExecutionLog)
        }

        let endedBy = TestRun.Ending(ending.reason)
        return TestRun(
            outcome: testResult,
            testLog: testExecutionLog,
            ending: endedBy,
            exitStatus: endedBy == .exited ? process.terminationStatus : nil
        )
    }

    /// Launches `process` and waits for it to exit. With a follower, stops it at the first failed test its
    /// log shows. Cancelling the calling task kills the process tree: waiting ignores cancellation, so the
    /// run would otherwise go on until its tests ended. While it runs, it is recorded in the mutated project's
    /// lock, so that if SwiftMutator dies first, killed or crashed, it is killed too (see `MutatedProjectLock`).
    private static func runToExit(
        _ process: Process,
        follower: TestLogFollower?,
        ending: TestRunEnding,
        recordingIn locker: MutatedProjectLocking
    ) async throws {
        // Foundation calls this as soon as it reaps the process, which can be before `run()` returns. The exit is
        // recorded first, so neither the follower nor the time limit kills a process that has exited, and reports a
        // run that ended by itself as stopped. Waiting for the handler holds no thread, unlike `waitUntilExit()`, which
        // also notices the exit up to about 60 ms later.
        let exited = Latch()
        process.terminationHandler = ending.recordingExit(opening: exited)
        try process.run()
        locker.testProcessStarted(process.processIdentifier)
        defer { locker.testProcessEnded(process.processIdentifier) }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                if let follower {
                    group.addTask {
                        guard let line = await follower.firstFailedTestLine(),
                              ending.record(.failedTest(line: line))
                        else { return }
                        process.terminateTree()
                    }
                }
                await exited.wait()
                // Stops the follower if it is still watching. The group waits for it, so it never outlives the run.
                group.cancelAll()
            }
        } onCancel: {
            if ending.record(.cancelled) {
                process.terminateTreeInBackground()
            }
        }
    }

    /// How long a run that may have ended by a signal from outside waits before it is recorded. Measured: a run is
    /// recorded 1–65 ms after its test process dies, and with SwiftMutator signalled 5–50 ms after the test process,
    /// 8 of 15 such runs were recorded as killed.
    static let outsideSignalWait: UInt64 = 250_000_000

    /// Whether `process`, which has exited, may have ended by a stopping signal sent from outside SwiftMutator:
    /// SIGINT, SIGTERM or SIGHUP. An ordinary test failure exits 1, a crash dies of another signal, and SwiftMutator's
    /// own SIGKILL ends a run for another reason, so none of them wait.
    static func mayHaveEndedByAnOutsideSignal(_ process: Process) -> Bool {
        switch process.terminationReason {
        case .uncaughtSignal:
            return [SIGINT, SIGTERM, SIGHUP].contains(process.terminationStatus)
        // swiftly's proxy, and shells, pass a child's signal on as its number or 128 + it.
        case .exit:
            return [2, 15, 129, 130, 143].contains(process.terminationStatus)
        @unknown default:
            return false
        }
    }

    /// The note that ends a stopped run's log: why it ends there, and the line that stopped it. Appended after
    /// the run is classified, so it can't change the outcome. Its lines start with `[SwiftMutator]`, so
    /// `FailedTestLine` doesn't match them if the log is read again.
    static func noteForRunStopped(at failedTestLine: String, after log: String) -> String {
        // The run was killed wherever its output was, often partway through a line.
        let lineBreak = log.isEmpty || log.hasSuffix("\n") ? "" : "\n"
        return lineBreak + """

            [SwiftMutator] Stopped this test run at its first failed test (stopAtFirstFailure); the tests after it did not run.
            [SwiftMutator] The line that stopped it: \(failedTestLine)

            """
    }

    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL
    ) async throws {
        let updated = testRun.updateEnvironmentVariable(
            setting: schemata.id
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .xml,
            options: 0
        )

        try data.write(
            to: path.appendingPathComponent(muterTestRunFileName)
        )
    }

    func testProcess(
        with configuration: MuterConfiguration,
        schemata: MutationSchema,
        and fileHandle: FileHandle,
        workingDirectory: URL? = nil,
        skippingBuild: Bool? = nil
    ) async throws -> Process {
        // A mutant's run skips the build the baseline did, and so does the run that times one with no mutant on.
        let testCommandArguments = (skippingBuild ?? (schemata != .null))
            ? configuration.testWithoutBuildArguments(with: muterTestRunFileName)
            : configuration.testCommandArguments

        let process = process()

        // Set the muter marker only on the TEST process, not the shared build process (see
        // MuterProcessFactory) — it's not needed at build time and setting it there can suppress
        // xcodebuild's build-request.json.
        process.environment?[isMuterRunningKey] = isMuterRunningValue

        if configuration.stopsAtFirstFailure {
            // `swift test` relays its test runners' output through its own standard output, which holds
            // output bound for a file 4 KiB at a time until it exits: a run stopped at its first failed test
            // would show that failure late, or lose its whole log. Set on the baselines and the timed test run
            // too, although they are never stopped, so they run as the mutants that stop do, and the time limit
            // derived from them allows for unbuffered output. Mutants run without it once a passing baseline's
            // failure-like line has turned stopping off for them.
            process.environment?[unbufferedOutputKey] = unbufferedOutputValue
        }

        if configuration.buildSystem == .swift {
            // SwiftPM keys its cache of compiled package manifests on the whole environment, so a variable of the
            // mutant's own made every run recompile every manifest. A worker's runs, baseline included, name one file
            // instead, written here before the run starts and read lazily by the generated code. A worker runs one
            // test process at a time (see PerformMutationTesting.testMutationsInParallel), so nothing rewrites it
            // during a run.
            let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
            let activeMutantFile = Self.activeMutantFile(forWorkerIn: folder).path
            try writeFile(schemata == .null ? "" : schemata.id, activeMutantFile)
            process.environment?[activeMutantFileKey] = activeMutantFile
        } else if schemata != .null {
            process.environment?[schemata.id] = "YES"
            // Also forward the activation var into an iOS Simulator test host. When xcodebuild spawns
            // tests in the simulator, CoreSimulator only propagates env vars prefixed `SIMCTL_CHILD_`
            // into the simulated process; a bare var set on this (parent) process never reaches the
            // test host, so the mutant wouldn't activate. Complements the xctestrun `EnvironmentVariables` path.
            process.environment?["SIMCTL_CHILD_\(schemata.id)"] = "YES"
        }

        process.arguments = testCommandArguments
        process.executableURL = URL(fileURLWithPath: configuration.testCommandExecutable)
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        process.standardOutput = fileHandle
        process.standardError = fileHandle

        return process
    }

    /// Opens `logFileName`, a path relative to the current directory or an absolute one, empty, making its folder if
    /// need be.
    func fileHandle(
        for logFileName: String
    ) throws -> (
        handle: FileHandle,
        logFileUrl: URL
    ) {
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let testLogUrl = URL(fileURLWithPath: logFileName, relativeTo: currentDirectory).absoluteURL
        try FileManager.default.createDirectory(
            at: testLogUrl.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: testLogUrl)

        return try (
            handle: FileHandle(forWritingTo: testLogUrl),
            logFileUrl: testLogUrl
        )
    }
}
