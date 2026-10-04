import Foundation

protocol MutationTestingIODelegate {
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    )

    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)` with the test command run in
    /// `workingDirectory`, a parallel worker's clone of the mutated project. The log is still saved
    /// in the current directory.
    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    )

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    )

    /// `benchmarkTests(using:savingResultsIntoFileNamed:)` with the test command, build included, run
    /// in `workingDirectory`, a parallel worker's clone of the mutated project. The log is still saved
    /// in the current directory.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
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
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.process)
    private var process: ProcessFactory
    @Dependency(\.testingTimeOutExecutor)
    private var testingTimeOutExecutor: TestingTimeoutExecutorFactory

    private let muterTestRunFileName = "muter.xctestrun"

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true
        )
    }

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true,
            workingDirectory: workingDirectory
        )
    }

    func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
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
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
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
        workingDirectory: URL? = nil
    ) async -> (
        outcome: TestSuiteOutcome,
        testLog: String
    ) {
        do {
            let (testProcessFileHandle, testLogUrl) = try fileHandle(for: fileName)
            defer { try? testProcessFileHandle.close() }

            let process = try await testProcess(
                with: configuration,
                schemata: schemata,
                and: testProcessFileHandle,
                workingDirectory: workingDirectory
            )

            let timeout = isBenchmark ? nil : configuration.testSuiteTimeout
            // Never a baseline, the mutated project's or a worker's: whether it passes decides whether mutation
            // testing can start, so it always runs to its end. A run with no mutant switched on is one too.
            let stopsAtFirstFailure = !isBenchmark && schemata != .null && configuration.stopsAtFirstFailure
            let (outcome, contents) = try await runTestProcess(
                process,
                logFileUrl: testLogUrl,
                withTimeout: timeout,
                stoppingAtFirstFailure: stopsAtFirstFailure,
                failedTestLinesAreReliable: configuration.failedTestLinesAreReliable
            )

            return (
                outcome: outcome,
                testLog: contents
            )

        } catch {
            // Reaching here means the test command never ran — the log file couldn't be opened, or
            // the process failed to spawn. There is no test output to report, so the thrown error is
            // the only evidence of what went wrong; return it as the log rather than an empty string,
            // which leaves the caller with nothing to show the user. A cancelled run also ends here; whoever
            // cancelled it doesn't use its outcome.
            return (
                .buildError,
                """
                SwiftMutator could not run your test command and captured no test output.

                  executable: \(configuration.testCommandExecutable)
                  arguments: \(configuration.testCommandArguments.joined(separator: " "))
                  working directory: \(fileManager.currentDirectoryPath)

                \(error.localizedDescription)
                """
            )
        }
    }

    private func runTestProcess(
        _ process: Process,
        logFileUrl: URL,
        withTimeout timeout: TimeInterval?,
        stoppingAtFirstFailure: Bool,
        failedTestLinesAreReliable: Bool
    ) async throws -> (TestSuiteOutcome, String) {
        let ending = TestRunEnding()
        let follower = stoppingAtFirstFailure ? TestLogFollower(logFileUrl: logFileUrl) : nil
        let run: @Sendable () async throws -> TestingExecutionResult = {
            try await Self.runToExit(process, follower: follower, ending: ending)
            return .success
        }
        if let timeout {
            _ = try await testingTimeOutExecutor().withTimeLimit(timeout, run) {
                // Kill the whole process tree, not just the launched command — see terminateTree(). Only if
                // nothing ended the run first: its process may have just exited, or been stopped at a failed test.
                if ending.record(.timedOut) { process.terminateTree() }
                return .timeout
            }
        } else {
            _ = try await run()
        }

        // withTimeLimit returns whichever of its tasks finishes first, which needn't be what ended the run.
        let executionResult = try ending.executionResult()
        // Decoded leniently: the log is whatever the test command wrote, and a run stopped at the time
        // limit, or a test process that crashed mid-write, can end partway through a character. Strict
        // decoding threw on that, and the run was reported as a build error, outside the score.
        var testExecutionLog = try String(decoding: Data(contentsOf: logFileUrl), as: UTF8.self)
        let testResult = TestSuiteOutcome.from(
            testLog: testExecutionLog,
            terminationStatus: process.terminationStatus,
            timeoutExecution: executionResult,
            failedTestLinesAreReliable: failedTestLinesAreReliable
        )
        if case let .failedTest(line) = ending.reason {
            testExecutionLog += Self.noteForRunStopped(at: line, after: testExecutionLog)
        }

        return (testResult, testExecutionLog)
    }

    /// Launches `process` and waits for it to exit. With a follower, stops it at the first failed test its
    /// log shows. Cancelling the calling task kills the process tree: waiting ignores cancellation, so the
    /// run would otherwise go on until its tests ended.
    private static func runToExit(_ process: Process, follower: TestLogFollower?, ending: TestRunEnding) async throws {
        // Foundation calls this as soon as it reaps the process, while waitUntilExit() notices the exit up to
        // about 60 ms later. Recording the exit here closes that gap: in it, the follower or the time limit
        // could kill a process that had exited, and report a run that ended by itself as stopped.
        process.terminationHandler = { _ in _ = ending.record(.exited) }
        try process.run()
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
                await process.exited()
                // For a process that doesn't call terminationHandler, such as a test double.
                _ = ending.record(.exited)
                // Stops the follower if it is still watching. The group waits for it, so it never outlives the run.
                group.cancelAll()
            }
        } onCancel: {
            if ending.record(.cancelled) {
                process.terminateTreeInBackground()
            }
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
        workingDirectory: URL? = nil
    ) async throws -> Process {
        let testCommandArguments = schemata == .null
            ? configuration.testCommandArguments
            : configuration.testWithoutBuildArguments(with: muterTestRunFileName)

        let process = process()

        // Set the muter marker only on the TEST process, not the shared build process (see
        // MuterProcessFactory) — it's not needed at build time and setting it there can suppress
        // xcodebuild's build-request.json.
        process.environment?[isMuterRunningKey] = isMuterRunningValue

        if configuration.stopsAtFirstFailure {
            // `swift test` relays its test runners' output through its own standard output, which holds
            // output bound for a file 4 KiB at a time until it exits: a run stopped at its first failed test
            // would show that failure late, or lose its whole log. Set on the baselines too, although they are
            // never stopped, so they run as the mutants that stop do, and the time limit derived from them
            // allows for unbuffered output. Mutants run without it once a passing baseline's failure-like line
            // has turned stopping off for them.
            process.environment?[unbufferedOutputKey] = unbufferedOutputValue
        }

        if schemata != .null {
            process.environment?[schemata.id] = "YES"
            // Also forward the activation var into an iOS Simulator test host. When xcodebuild spawns
            // tests in the simulator, CoreSimulator only propagates env vars prefixed `SIMCTL_CHILD_`
            // into the simulated process; a bare var set on this (parent) process never reaches the
            // test host, so the mutant wouldn't activate. Harmless for non-simulator (swift/macOS) runs,
            // which read the bare var directly. Complements the xctestrun `EnvironmentVariables` path.
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

    func fileHandle(
        for logFileName: String
    ) throws -> (
        handle: FileHandle,
        logFileUrl: URL
    ) {
        let testLogUrl = URL(
            fileURLWithPath: fileManager.currentDirectoryPath + "/" + logFileName
        )
        try Data().write(to: testLogUrl)

        return try (
            handle: FileHandle(forWritingTo: testLogUrl),
            logFileUrl: testLogUrl
        )
    }
}
