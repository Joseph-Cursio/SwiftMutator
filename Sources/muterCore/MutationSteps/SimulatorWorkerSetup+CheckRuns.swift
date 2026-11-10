import Foundation

/// The xcodebuild workers' runs with no mutant on, one on each simulator, which decide whether they test mutants.
extension SimulatorWorkerSetup {
    /// The name of the log of xcodebuild worker `worker`'s run with no mutant on.
    static func checkRunLogName(ofWorker worker: Int) -> String {
        "no-mutant run worker \(worker).log"
    }

    /// A worker's run with no mutant on, the run before it, if the simulator failed to launch that one, how long both
    /// took, and the file it wrote its output to, none if it never ran.
    struct CheckRun {
        let worker: Int
        let outcome: TestSuiteOutcome
        let testLog: String
        /// Whether it was stopped at `buildTimeout`.
        let timedOut: Bool
        let launchFailure: LaunchFailure?
        let seconds: TimeInterval
        let output: String?

        init(_ worker: Int, _ run: TestRun, launchFailure: LaunchFailure?, seconds: TimeInterval, output: String?) {
            self.worker = worker
            outcome = run.outcome
            testLog = run.testLog
            timedOut = run.ending == .timedOut
            self.launchFailure = launchFailure
            self.seconds = seconds
            self.output = output
        }
    }

    /// Runs the tests with no mutant on, on every one of `xcodeWorkers` at once, each from its own `.xctestrun`, and
    /// returns the runs in worker order. A worker whose `.xctestrun` can't be written fails its run. A run the
    /// simulator failed to launch runs once more on its worker, unless the run is stopped, and the second is returned.
    func checkRuns(
        on xcodeWorkers: [MuterConfiguration.XcodeWorker],
        configuration: MuterConfiguration,
        state: AnyMutationTestState,
        testOutput: (String) -> String
    ) async -> [CheckRun] {
        let (testRun, mutatedProject) = (state.projectXCTestRun, state.mutatedProjectDirectoryURL)
        let runs = await withTaskGroup(of: CheckRun.self) { group in
            for (worker, xcodeWorker) in xcodeWorkers.enumerated() {
                let workerConfiguration = configuration.forXcodeWorker(xcodeWorker)
                let fileName = testOutput("no-mutant run worker \(worker)")
                // A worker's run is given the values and the dependency it uses, not the setup or the state.
                group.addTask { [ioDelegate, instant] in
                    do {
                        try await ioDelegate.switchOn(
                            schemata: .null, for: testRun, at: mutatedProject, named: xcodeWorker.testRunFile
                        )
                    } catch {
                        let why = error.localizedDescription
                        let log = "SwiftMutator could not write \(xcodeWorker.testRunFile): \(why)"
                        let run = TestRun(outcome: .buildError, testLog: log)
                        return CheckRun(worker, run, launchFailure: nil, seconds: 0, output: nil)
                    }
                    let start = instant()
                    let (run, launchFailure) = await TestRun.launchedOnceMore(ifNeededWith: workerConfiguration) {
                        await ioDelegate.runTestsWithoutBuilding(
                            using: workerConfiguration,
                            timeLimit: workerConfiguration.buildTimeout,
                            savingResultsIntoFileNamed: fileName
                        )
                    }
                    let seconds = PerformMutationTesting.seconds(from: start, to: instant())
                    return CheckRun(worker, run, launchFailure: launchFailure, seconds: seconds, output: fileName)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        return runs.sorted { $0.worker < $1.worker }
    }

    /// Keeps each of `runs`' logs, and that of the run before it that the simulator failed to launch, in the run's log
    /// folder, and gives where each run's is, in worker order.
    func keepLogs(of runs: [CheckRun], state: AnyMutationTestState) -> [String?] {
        runs.map { run in
            let logName = Self.checkRunLogName(ofWorker: run.worker)
            if let failure = run.launchFailure {
                fileManager.keepLog(
                    failure.testLog, named: MutationTestLog.launchFailedFileName(for: logName), state: state
                )
            }
            return fileManager.keepLog(run.testLog, writtenTo: run.output, by: ioDelegate, named: logName, state: state)
        }
    }

    /// One worker, on the test command's destination, once `failed`, a worker's run with no mutant on, didn't pass,
    /// with why, which names its log if it `keptLog`. The simulators are deleted first; a stop meanwhile throws.
    func fallingBack(
        after failed: CheckRun,
        keptLog: Bool,
        configuration: MuterConfiguration
    ) async throws -> Workers {
        await workerSimulators.removeAll()
        // A stop while they were deleted.
        try Task.checkCancellation()
        let why = SimulatorTrouble.first(inLog: failed.testLog).map { ": \($0.line)" } ?? ""
        let log = keptLog ? " (its log is \(Self.checkRunLogName(ofWorker: failed.worker)))" : ""
        let ended = failed.timedOut
            ? "didn't end within \(String(format: "%g", configuration.buildTimeout ?? 0)) s (buildTimeout)"
            : "didn't pass\(why)"
        let reason = "worker \(failed.worker)'s run with no mutant on, on its simulator, \(ended)\(log)"
        return Workers(count: 1, unavailable: reason, configuration: configuration, xcodeWorkers: [])
    }
}
