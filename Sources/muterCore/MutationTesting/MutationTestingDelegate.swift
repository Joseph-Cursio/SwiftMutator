#if os(Linux)
import Glibc
#else
import Darwin.C
#endif
import Foundation

struct MutationTestingDelegate: MutationTestingIODelegate {
    @Dependency(\.fileManager)
    var fileManager: FileSystemManager
    @Dependency(\.mutatedProjectLocker)
    var mutatedProjectLocker: MutatedProjectLocking
    @Dependency(\.process)
    var process: ProcessFactory
    @Dependency(\.sleep)
    var sleep: Sleep
    @Dependency(\.testingTimeOutExecutor)
    var testingTimeOutExecutor: TestingTimeoutExecutorFactory
    @Dependency(\.writeFile)
    var writeFile: WriteFile
    @Dependency(\.makeFolder)
    var makeFolder: MakeFolder

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
            alwaysSkippingBuild: true
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
            alwaysSkippingBuild: true,
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
        alwaysSkippingBuild: Bool = false,
        workingDirectory: URL? = nil
    ) async -> TestRun {
        do {
            let (testProcessFileHandle, testLogUrl) = try fileHandle(for: fileName)
            defer { try? testProcessFileHandle.close() }

            let launchedProcess = try testProcess(
                with: configuration,
                schemata: schemata,
                and: testProcessFileHandle,
                workingDirectory: workingDirectory,
                alwaysSkippingBuild: alwaysSkippingBuild
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

    func switchOn(
        schemata: MutationSchema,
        for testRun: XCTestRun,
        at path: URL,
        named fileName: String
    ) throws {
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
