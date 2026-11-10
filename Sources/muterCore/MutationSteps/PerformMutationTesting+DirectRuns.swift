import Foundation

/// The run, after the baseline, that checks whether a SwiftPM run's mutants can run their test bundles without
/// `swift test`, and times a mutant's run.
extension PerformMutationTesting {
    /// `configuration` with a SwiftPM run's mutants running their test bundles directly when a run that checks it,
    /// which times it too, passes (`runningTestBundlesDirectly`), and whether that run wrote nothing in the project.
    /// A reuse with nothing left to test ran the baseline only to see that the changed tests pass. One mutant's run
    /// saves no more than either costs. The project's files are read only for a run that could share a build. That run
    /// may take as long as a run that follows the baseline (`followingRunLimit`), from its `baselineSeconds`.
    func directRuns(
        of plan: ResumePlan,
        _ configuration: MuterConfiguration,
        baselineLog: String,
        baselineSeconds: TimeInterval,
        state: AnyMutationTestState
    ) async throws -> DirectRuns {
        guard configuration.buildSystem == .swift, !plan.toRun.isEmpty, state.selectedMutant == nil else {
            return DirectRuns(configuration: configuration, seconds: nil, wroteNothing: false)
        }
        let timeLimit = Self.followingRunLimit(
            buildTimeout: configuration.buildTimeout, baselineSeconds: baselineSeconds
        )
        return try await runningTestBundlesDirectly(
            configuration,
            baselineLog: baselineLog,
            timeLimit: timeLimit,
            watchingFiles: configuration.workersShareBuild != false
                && configuration.workerCount(testing: plan.toRun.count, sharingBuild: true) > 1,
            state: state
        )
    }

    /// `configuration` with mutants' tests run without `swift test`, if a run of them with no mutant on, once the
    /// baseline has built the project, passes and runs the tests the baseline's log shows, with how long it took. Else
    /// `configuration` as it is, and why, unless it isn't worth saying. A run that fails the check keeps its log. With
    /// `watchingFiles`, the project's files are read before and after that run, each path's size and time, `.build`
    /// included: anything it wrote there, even if it removed it again, means workers can't share a build. A run stopped
    /// at `timeLimit` fails the check.
    func runningTestBundlesDirectly(
        _ configuration: MuterConfiguration,
        baselineLog: String,
        timeLimit: TimeInterval?,
        watchingFiles: Bool,
        state: AnyMutationTestState
    ) async throws -> DirectRuns {
        let notRunDirectly = DirectRuns(configuration: configuration, seconds: nil, wroteNothing: false)
        let notDirect = { (reason: String) in
            events.send(.testBundlesNotRunDirectly(reason: reason))
            return notRunDirectly
        }
        let direct: DirectTestRun
        switch await directTestRun(configuration, state.mutatedProjectDirectoryURL) {
        case let .success(probed):
            direct = probed

        case let .failure(unavailable):
            try Task.checkCancellation()
            return unavailable.reason.map(notDirect) ?? notRunDirectly
        }
        try Task.checkCancellation()
        if DirectTestRun.ranXCTestTests(in: baselineLog) {
            return notDirect("the baseline ran XCTest tests, which only `swift test` runs")
        }

        let directConfiguration = configuration.withDirectTestRun(direct)
        let filesBefore = watchingFiles ? projectFiles(state.mutatedProjectDirectoryURL) : nil
        let start = instant()
        let output = testOutput(named: "direct test run", state: state)
        let run = await ioDelegate.runTestsWithoutBuilding(
            using: directConfiguration,
            timeLimit: timeLimit,
            savingResultsIntoFileNamed: output
        )
        let testLog = run.testLog
        // Stopping the run kills this run too, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()
        let seconds = seconds(since: start)
        let filesAfter = watchingFiles ? projectFiles(state.mutatedProjectDirectoryURL) : nil
        let whyNot = Self.whyNotRunDirectly(after: run, timeLimit: timeLimit, baselineLog: baselineLog)
        let logName = whyNot == nil ? TimedTestRun.logName : "direct test run.log"
        fileManager.keepLog(testLog, writtenTo: output, by: ioDelegate, named: logName, state: state)
        if let whyNot {
            return notDirect(whyNot + " (its log is direct test run.log)")
        }
        let firstChange = filesAfter.flatMap { filesBefore?.firstChange(in: $0) }
        if let firstChange {
            events.send(.testBundlesWroteInTheProject(path: firstChange))
        }
        return DirectRuns(
            configuration: directConfiguration,
            seconds: seconds,
            wroteNothing: filesBefore != nil && filesAfter != nil && firstChange == nil
        )
    }

    /// Why `run`, of the test bundles with no mutant on, fails the check for direct runs: it was stopped at
    /// `timeLimit`, or it didn't pass and run the tests `baselineLog` shows (`DirectTestRun.whyNot`). nil when it
    /// passes the check.
    static func whyNotRunDirectly(after run: TestRun, timeLimit: TimeInterval?, baselineLog: String) -> String? {
        run.ending == .timedOut
            ? "the run of the test bundles with no mutant on didn't end within "
                + "\(String(format: "%g", timeLimit ?? 0)) s, so SwiftMutator stopped it"
            : DirectTestRun.whyNot(baselineLog: baselineLog, outcome: run.outcome, log: run.testLog)
    }

    /// The seconds from `start` to now, on the monotonic clock.
    func seconds(since start: DispatchTime) -> TimeInterval {
        Self.seconds(from: start, to: instant())
    }
}
