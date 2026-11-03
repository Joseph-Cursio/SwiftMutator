import Foundation

/// The run of a mutant's test command with no mutant on, once the baseline has built the project, that the default time
/// limit for a mutant's run comes from (`PerformMutationTesting.defaultTimeout(testRunSeconds:workers:)`).
struct TimedTestRun {
    @Dependency(\.ioDelegate)
    private var ioDelegate: MutationTestingIODelegate
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.instant)
    private var instant: Instant

    static let logName = "timed test run.log"

    /// How long a mutant's test command, with `configuration`, takes with no mutant on, or nil if that run didn't pass:
    /// one that crashed at once says nothing about how long a passing one takes. It writes its output to `testOutput`,
    /// and its log is kept. An xcodebuild worker's run tests from its `.xctestrun`, written first with no mutant
    /// switched on, or is nil if that can't be written; the first mutant's switch then says why. A run the simulator
    /// failed to launch runs once more, as a mutant's does, and only the second is timed; the first's log is kept
    /// beside it. A stop throws.
    func seconds(
        using configuration: MuterConfiguration,
        state: AnyMutationTestState,
        testOutput: String
    ) async throws -> TimeInterval? {
        if let worker = configuration.xcodeWorker {
            do {
                try await ioDelegate.switchOn(
                    schemata: .null,
                    for: state.projectXCTestRun,
                    at: state.mutatedProjectDirectoryURL,
                    named: worker.testRunFile
                )
            } catch {
                return nil
            }
        }
        var start = instant()
        let (run, launchFailure) = await TestRun.launchedOnceMore(
            ifNeededWith: configuration,
            relaunching: { start = instant() },
            running: {
                let (outcome, testLog) = await ioDelegate.runTestsWithoutBuilding(
                    using: configuration,
                    savingResultsIntoFileNamed: testOutput
                )
                return TestRun(outcome: outcome, testLog: testLog)
            }
        )
        // Stopping the run kills this run too, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()
        let seconds = run.outcome == .passed ? PerformMutationTesting.seconds(from: start, to: instant()) : nil
        if let launchFailure {
            fileManager.keepLog(
                launchFailure.testLog, named: MutationTestLog.launchFailedFileName(for: Self.logName), state: state
            )
        }
        fileManager.keepLog(run.testLog, named: Self.logName, state: state)
        return seconds
    }
}
