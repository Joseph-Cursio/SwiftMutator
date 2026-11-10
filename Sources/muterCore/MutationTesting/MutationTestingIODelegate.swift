#if os(Linux)
import Glibc
#else
import Darwin.C
#endif
import Foundation

// A pure-Swift async injection seam (an I/O *dependency*), not an Objective-C delegate, so the
// `class_delegate_protocol` expectation of a `class`/`@objc`-based protocol does not apply here.
// swiftlint:disable:next class_delegate_protocol
protocol MutationTestingIODelegate: Sendable {
    /// Runs the test command with `schemata` switched on. Its output goes to `fileName`, a path relative to the
    /// current directory or an absolute one, whose folder is made if need be. The file stays once its log has been read
    /// back, for the caller to keep or discard (`keepOutput(at:as:)`), so a run that is never recorded, one a stop cut
    /// short or one that finished as a stop or an abort came, leaves it where it is.
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

    /// A baseline: the whole test command, build included, with no mutant switched on, stopped once it has run for
    /// `buildTimeout` seconds, if that is set, which its ending then says. `fileName` is as in
    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun

    /// `benchmarkTests(using:savingResultsIntoFileNamed:)` with the test command, build included, run
    /// in `workingDirectory`, a parallel worker's clone of the mutated project. A relative `fileName` is still taken
    /// from the current directory, not `workingDirectory`.
    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun

    /// A mutant's test command, which skips the build, with no mutant switched on, once the baseline has built the
    /// project: what a mutant's run costs. Never stopped at its first failed test, and stopped only once it has run for
    /// `timeLimit` seconds, if that isn't nil, which its ending then says. An xcodebuild worker's configuration runs it
    /// on that worker, from its `.xctestrun`, so it also checks the worker. `fileName` is as in
    /// `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        timeLimit: TimeInterval?,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun

    /// A control run: a mutant's test command, which skips the build, with no mutant switched on, under the mutants'
    /// time limit and never stopped at its first failed test, so its log shows every test that failed. Run among the
    /// mutants, in `workingDirectory`, a worker's folder, or the current directory if nil, under the same load. An
    /// xcodebuild worker's configuration runs it on that worker, from its `.xctestrun`, which must switch no mutant
    /// on. `fileName` is as in `runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)`.
    func runControlTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL?
    ) async -> TestRun

    /// Writes `testRun`, with `schemata`'s mutant switched on, to `fileName` in `path`, the `.xctestrun` an xcodebuild
    /// worker's runs test from. `.null` switches no mutant on, for a run with none.
    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL,
        named fileName: String
    ) async throws

    /// Moves the output file a run wrote, `output`, named as given to `runTestSuite`, to `path`, replacing any file
    /// there, or removes it when `path` is nil. Either path is relative to the current directory or an absolute one.
    /// Only a regular file is moved or removed, never a folder or a symbolic link. Whether the file was moved: false
    /// when there is none, or the move failed, and the output is then removed.
    @discardableResult
    func keepOutput(at output: String, as path: String?) -> Bool
}

extension MutationTestingIODelegate {
    /// `switchOn(schemata:for:at:named:)` to the first worker's `.xctestrun`, `muter.xctestrun`.
    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL
    ) async throws {
        try await switchOn(
            schemata: schemata,
            for: testRun,
            at: path,
            named: MutationTestingDelegate.muterTestRunFileName
        )
    }
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
    @Dependency(\.makeFolder)
    private var makeFolder: MakeFolder

    /// The `.xctestrun` file, at the mutated project's root, that `switchOn` writes and a mutant's xcodebuild run
    /// tests from, unless its configuration's `xcodeWorker` names another.
    static let muterTestRunFileName = "muter.xctestrun"

    /// The `.xctestrun` file, at the mutated project's root, that xcodebuild worker `worker`'s runs test from:
    /// `muter.xctestrun` for worker 0, and `muter-worker<n>.xctestrun` for worker n. Each worker has its own, so the
    /// mutant one worker switches on is never the one another's run tests. All of them sit where `muter.xctestrun`
    /// does, which the paths in it are relative to (see `BuildForTesting`).
    static func testRunFileName(ofWorker worker: Int) -> String {
        worker == 0 ? muterTestRunFileName : "\(workerTestRunFilePrefix)\(worker)\(workerTestRunFileSuffix)"
    }

    /// Whether `name` is `muter-worker<n>.xctestrun`, as `testRunFileName(ofWorker:)` names worker n's.
    static func isWorkerTestRunFileName(_ name: String) -> Bool {
        guard name.hasPrefix(workerTestRunFilePrefix), name.hasSuffix(workerTestRunFileSuffix) else { return false }
        let number = name.dropFirst(workerTestRunFilePrefix.count).dropLast(workerTestRunFileSuffix.count)
        return !number.isEmpty && number.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static let workerTestRunFilePrefix = "muter-worker"
    private static let workerTestRunFileSuffix = ".xctestrun"
    /// Ends the name of the file `activeMutantFileKey` names, beside a worker's folder.
    static let activeMutantFileSuffix = ".active-mutant"

    /// The file `activeMutantFileKey` names for a worker's folder, the mutated project or a clone:
    /// `<stem>.active-mutant`, beside it, named after the folder without `.noindex`, as SwiftMutators from before
    /// `.noindex` named it (`MutatedProjectNames.file(_:beside:)`). Never in it: the folder is a whole copy of the
    /// project, `.git` included, so a test that lists the package's hidden files, or needs a clean `git status`, would
    /// see it. Its path is the same for every run of the worker, as one environment for them all needs, and for every
    /// SwiftMutator run.
    static func activeMutantFile(forWorkerIn folder: URL) -> URL {
        MutatedProjectNames.file(activeMutantFileSuffix, beside: folder)
    }

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun {
        await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true,
            timeLimit: configuration.buildTimeout
        )
    }

    func benchmarkTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL
    ) async -> TestRun {
        await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true,
            timeLimit: configuration.buildTimeout,
            workingDirectory: workingDirectory
        )
    }

    func runTestsWithoutBuilding(
        using configuration: MuterConfiguration,
        timeLimit: TimeInterval?,
        savingResultsIntoFileNamed fileName: String
    ) async -> TestRun {
        await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: true,
            timeLimit: timeLimit,
            skippingBuild: true
        )
    }

    func runControlTests(
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        workingDirectory: URL?
    ) async -> TestRun {
        await runTestSuite(
            withSchemata: .null,
            using: configuration,
            savingResultsIntoFileNamed: fileName,
            isBenchmark: false,
            timeLimit: configuration.testSuiteTimeout,
            skippingBuild: true,
            workingDirectory: workingDirectory
        )
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
            isBenchmark: false,
            timeLimit: configuration.testSuiteTimeout
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
            timeLimit: configuration.testSuiteTimeout,
            workingDirectory: workingDirectory
        )
    }

    private func runTestSuite(
        withSchemata schemata: MutationSchema,
        using configuration: MuterConfiguration,
        savingResultsIntoFileNamed fileName: String,
        isBenchmark: Bool,
        timeLimit: TimeInterval?,
        skippingBuild: Bool? = nil,
        workingDirectory: URL? = nil
    ) async -> TestRun {
        do {
            let (testProcessFileHandle, testLogUrl) = try fileHandle(for: fileName)
            defer { try? testProcessFileHandle.close() }

            let launchedProcess = try await testProcess(
                with: configuration,
                schemata: schemata,
                and: testProcessFileHandle,
                workingDirectory: workingDirectory,
                skippingBuild: skippingBuild
            )

            // Never a baseline, the mutated project's or a worker's: whether it passes decides whether mutation
            // testing can start, so it runs to its end, or its time limit. A run with no mutant switched on is one too.
            let stopsAtFirstFailure = !isBenchmark && schemata != .null && configuration.stopsAtFirstFailure
                && !configuration.runsGoToTheirEnd
            var run = try await runTestProcess(
                launchedProcess,
                logFileUrl: testLogUrl,
                withTimeout: timeLimit,
                stoppingAtFirstFailure: stopsAtFirstFailure,
                failedTestLinesAreReliable: configuration.failedTestLinesAreReliable
            )
            if schemata != .null {
                run.activated = readActivation(
                    of: marker(of: schemata, using: configuration, workingDirectory: workingDirectory)
                )
            }
            return run
        } catch {
            // Reaching here means the test command never ran — the log file couldn't be opened, or
            // the process failed to spawn. There is no test output to report, so the thrown error is
            // the only evidence of what went wrong; return it as the log rather than an empty string,
            // which leaves the caller with nothing to show the user. A cancelled run ends here too, by the
            // CancellationError of its ending or of its time limit's task. Its outcome then says nothing
            // about the mutant, and its ending says so.
            let ending: TestRun.Ending = error is CancellationError || Task.isCancelled ? .cancelled : .couldNotRun
            // A stopped run's output stays, to show what the run was doing. A run that never started has none, so
            // whatever is at its output's name goes, even when it wasn't opened: an empty file made just before the
            // open failed, or one left there before, would otherwise be kept as its log in place of this explanation.
            // Only a file goes, never a folder.
            if ending == .couldNotRun {
                unlink(outputUrl(for: fileName).path)
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

    /// `schemata`'s marker for runs with `configuration` in `workingDirectory`, or the current directory if nil.
    private func marker(
        of schemata: MutationSchema,
        using configuration: MuterConfiguration,
        workingDirectory: URL?
    ) -> ActivationMarker {
        let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let testRunFile = configuration.buildSystem == .xcodebuild
            ? configuration.xcodeWorker?.testRunFile ?? Self.muterTestRunFileName
            : nil
        return ActivationMarker(of: schemata, forWorkerIn: folder, testRunFile: testRunFile)
    }

    /// Empties `marker`'s place for the run about to start, so that it shows that run alone, and makes its folder. On
    /// the real disk, as a run's output is: its test process writes there, from outside this process.
    private func clearActivation(of marker: ActivationMarker) {
        let files = FileManager.default
        try? files.removeItem(atPath: marker.path)
        try? files.removeItem(atPath: marker.reachedPath)
        try? files.createDirectory(
            atPath: marker.path.deletingLastPathComponent,
            withIntermediateDirectories: true
        )
    }

    /// What `marker` shows of the run that has just ended (`TestRun.activated`), and removes it.
    private func readActivation(of marker: ActivationMarker) -> Bool? {
        defer { clearActivation(of: marker) }
        if FileManager.default.fileExists(atPath: marker.path) { return true }
        return FileManager.default.fileExists(atPath: marker.reachedPath) ? false : nil
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
        // command milliseconds before SwiftMutator's own signal stops mutation testing; the run would be recorded
        // first, as a crash, which counts as killed. Only a run that seems to have died of such a signal waits:
        // SwiftMutator's own kills end a run for another reason. A cancellation in the wait throws, and the run reads
        // as cancelled.
        let exit = ending.exit(of: process)
        if ending.reason == .exited, Self.mayHaveEndedByAnOutsideSignal(exit) {
            try await sleep(Self.outsideSignalWait)
        }

        // withTimeLimit returns whichever of its tasks finishes first, which needn't be what ended the run.
        let executionResult = try ending.executionResult()
        // Decoded leniently: the log is whatever the test command wrote, and a run stopped at the time
        // limit, or a test process that crashed mid-write, can end partway through a character. Strict
        // decoding threw on that, and the run was reported as a build error, outside the score.
        var testExecutionLog = try String(decoding: Data(contentsOf: logFileUrl), as: UTF8.self)
        // Read back, the file stays: whatever records the run moves it to its log's kept name, or removes it.
        let testResult = TestSuiteOutcome.from(
            testLog: testExecutionLog,
            terminationStatus: exit.status,
            timeoutExecution: executionResult,
            failedTestLinesAreReliable: failedTestLinesAreReliable
        )
        let note: String? = switch ending.reason {
        case let .failedTest(line): Self.noteForRunStopped(at: line, after: testExecutionLog)
        case let .crashed(line): Self.noteForRunStopped(atCrash: line, after: testExecutionLog)
        default: nil
        }
        if let note {
            testExecutionLog += note
            // The file the log is kept from ends as the log does. Its process tree was killed, so nothing writes to it.
            Self.append(note, to: logFileUrl)
        }

        let endedBy = TestRun.Ending(ending.reason)
        return TestRun(
            outcome: testResult,
            testLog: testExecutionLog,
            ending: endedBy,
            exitStatus: endedBy == .exited ? exit.status : nil
        )
    }

    /// Launches `process` and waits for it to exit. With a follower, stops it at the first failed test or crash its
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
        // also notices the exit up to about 60 ms later. On Linux the kernel's report of the exit can come long before.
        let exited = Latch()
        process.terminationHandler = ending.recordingExit(opening: exited)
        try process.runWithNoSignalBlocked()
        process.watchForExit(recordingIn: ending, opening: exited)
        locker.testProcessStarted(process.processIdentifier)
        defer { locker.testProcessEnded(process.processIdentifier) }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                if let follower {
                    group.addTask {
                        guard let stop = await follower.firstStop(), ending.record(stop) else { return }
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
        // A kill finds its processes by listing the tree, which misses a test process the shell was starting as the
        // stop came, and one whose parent has ended. It would run on until its tests ended, reading later mutants'
        // active-mutant file, or for good if they hang. Each is still in the shell's group, and the shell, now ended,
        // starts no more. Side by side, killing at random moments in a run's first 400 ms, 51 of 34,213 kills left a
        // helper without this, and none of 34,191 with it. A helper of `swift test` leads its own group, so there this
        // finds only what `swift test` itself left.
        if ending.wasKilled { process.killProcessGroup() }
    }

    /// How long a run that may have ended by a signal from outside waits before it is recorded. Measured: a run is
    /// recorded 1–65 ms after its test process dies, and with SwiftMutator signalled 5–50 ms after the test process,
    /// 8 of 15 such runs were recorded as killed.
    static let outsideSignalWait: UInt64 = 250_000_000

    /// Whether a test process that ended as `exit` says may have ended by a stopping signal sent from outside
    /// SwiftMutator: SIGINT, SIGTERM or SIGHUP. An ordinary test failure exits 1, a crash dies of another signal, and
    /// SwiftMutator's own SIGKILL ends a run for another reason, so none of them wait.
    static func mayHaveEndedByAnOutsideSignal(_ exit: ProcessExit) -> Bool {
        switch exit.reason {
        case .uncaughtSignal:
            return [SIGINT, SIGTERM, SIGHUP].contains(exit.status)

        // swiftly's proxy, and shells, pass a child's signal on as its number or 128 + it.
        case .exit:
            return [2, 15, 129, 130, 143].contains(exit.status)

        @unknown default:
            return false
        }
    }

    /// The note that ends a stopped run's log: why it ends there, and the line that stopped it. Appended after
    /// the run is classified, so it can't change the outcome. Its lines start with `[SwiftMutator]`, so
    /// `FailedTestLine` doesn't match them if the log is read again.
    static func noteForRunStopped(at failedTestLine: String, after log: String) -> String {
        note(
            stopped: "at its first failed test (stopAtFirstFailure); the tests after it",
            at: failedTestLine,
            after: log
        )
    }

    /// The note that ends the log of a run stopped at a crash, as `noteForRunStopped(at:after:)` does.
    static func noteForRunStopped(atCrash crashLine: String, after log: String) -> String {
        note(stopped: "at a crash (stopAtFirstFailure); the test bundles after it", at: crashLine, after: log)
    }

    /// Appends `note` to the file at `url`. One that can't be written to keeps the log it has: the run's `testLog`
    /// still ends with the note.
    private static func append(_ note: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(note.utf8))
    }

    private static func note(stopped how: String, at line: String, after log: String) -> String {
        // The run was killed wherever its output was, often partway through a line.
        let lineBreak = log.isEmpty || log.hasSuffix("\n") ? "" : "\n"
        return lineBreak + """

            [SwiftMutator] Stopped this test run \(how) did not run.
            [SwiftMutator] The line that stopped it: \(line)

            """
    }

    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL,
        named fileName: String
    ) async throws {
        let updated = testRun.updateEnvironmentVariable(
            setting: schemata == .null ? nil : schemata.id,
            activationMarker: schemata == .null
                ? nil
                : ActivationMarker(of: schemata, forWorkerIn: path, testRunFile: fileName).path
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: updated,
            format: .xml,
            options: 0
        )

        try data.write(
            to: path.appendingPathComponent(fileName)
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
        let skipsBuild = skippingBuild ?? (schemata != .null)
        let testCommandArguments = skipsBuild
            ? configuration.testWithoutBuildArguments(with: Self.muterTestRunFileName)
            : configuration.testCommandArguments

        if skipsBuild, configuration.buildSystem == .xcodebuild, let worker = configuration.xcodeWorker {
            // Each run adds a result bundle and logs, which nothing reads, to the worker's derived data folder.
            // Emptied here, it holds one run's at most. Nothing in it is needed: the run tests the baseline's build.
            try? fileManager.removeItem(atPath: worker.derivedData)
        }

        let newProcess = process()

        // Set the muter marker only on the TEST process, not the shared build process (see
        // MuterProcessFactory) — it's not needed at build time and setting it there can suppress
        // xcodebuild's build-request.json.
        newProcess.environment?[isMuterRunningKey] = isMuterRunningValue

        if configuration.stopsAtFirstFailure {
            // `swift test` relays its test runners' output through its own standard output, which holds
            // output bound for a file 4 KiB at a time until it exits: a run stopped at its first failed test
            // would show that failure late, or lose its whole log. Set on the baselines and the timed test run
            // too, although they are never stopped, so they run as the mutants that stop do, and the time limit
            // derived from them allows for unbuffered output. Mutants run without it once a passing baseline's
            // failure-like line has turned stopping off for them.
            newProcess.environment?[unbufferedOutputKey] = unbufferedOutputValue
        }

        let marker = schemata == .null
            ? nil
            : marker(of: schemata, using: configuration, workingDirectory: workingDirectory)
        marker.map(clearActivation)

        if configuration.buildSystem == .swift {
            // SwiftPM keys its cache of compiled package manifests on the whole environment, so a variable of the
            // mutant's own made every run recompile every manifest. A worker's runs, baseline included, name one file
            // instead, written here before the run starts and read lazily by the generated code. A worker runs one
            // test process at a time (see PerformMutationTesting.testMutationsInParallel), so nothing rewrites it
            // during a run. Its second line names the run's activation marker.
            let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
            let activeMutantFile = Self.activeMutantFile(forWorkerIn: folder).path
            try writeFile(marker.map { schemata.id + "\n" + $0.path } ?? "", activeMutantFile)
            newProcess.environment?[activeMutantFileKey] = activeMutantFile
            // The same for each of the worker's runs too. `swift` stops at once if TMPDIR names no folder.
            let temporary = WorkerTemporaryFolder(forWorkerIn: folder, under: FileManager.default.temporaryDirectory)
            try makeFolder(temporary.path)
            newProcess.environment?.merge(temporary.environment) { _, own in own }
        } else if let marker {
            newProcess.environment?[schemata.id] = "YES"
            newProcess.environment?[activationMarkerKey] = marker.path
            // Also forward the activation var into an iOS Simulator test host. When xcodebuild spawns
            // tests in the simulator, CoreSimulator only propagates env vars prefixed `SIMCTL_CHILD_`
            // into the simulated process; a bare var set on this (parent) process never reaches the
            // test host, so the mutant wouldn't activate. Complements the xctestrun `EnvironmentVariables` path.
            newProcess.environment?["SIMCTL_CHILD_\(schemata.id)"] = "YES"
            newProcess.environment?["SIMCTL_CHILD_\(activationMarkerKey)"] = marker.path
        }

        if skipsBuild, let direct = configuration.directTestRun {
            let folder = workingDirectory ?? URL(fileURLWithPath: fileManager.currentDirectoryPath)
            let mutantFile = schemata == .null ? nil : schemata.filePath
            newProcess.arguments = ["-c", direct.script(in: folder, forMutantIn: mutantFile)]
            newProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        } else {
            newProcess.arguments = testCommandArguments
            newProcess.executableURL = URL(fileURLWithPath: configuration.testCommandExecutable)
        }
        // Workers that share a build have only a name each, which holds no folder to start in.
        if let folder = (skipsBuild ? configuration.directTestRun?.sharedBuild : nil) ?? workingDirectory {
            newProcess.currentDirectoryURL = folder
        }
        newProcess.standardOutput = fileHandle
        newProcess.standardError = fileHandle

        return newProcess
    }

    func keepOutput(at output: String, as path: String?) -> Bool {
        let source = outputUrl(for: output).path
        var status = stat()
        // Never a folder, such as the mutated project that an empty name would resolve to, nor a link's target.
        guard lstat(source, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return false }
        // Atomic within a volume, and `running/` is in the log folder the log is kept in.
        if let path, rename(source, outputUrl(for: path).path) == 0 {
            return true
        }
        unlink(source)
        return false
    }

    /// The file at `name`, a path relative to the current directory or an absolute one.
    private func outputUrl(for name: String) -> URL {
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: name, relativeTo: currentDirectory).absoluteURL
    }

    /// Opens `logFileName`, a path relative to the current directory or an absolute one, empty, making its folder if
    /// need be.
    func fileHandle(
        for logFileName: String
    ) throws -> (
        handle: FileHandle,
        logFileUrl: URL
    ) {
        let testLogUrl = outputUrl(for: logFileName)
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
