import Foundation

/// Gives each worker of an xcodebuild run whose first `-destination` is a simulator a simulator of its own, worker 0's
/// included: made like the destination's before the baseline, booted while the baseline runs, and checked once it has
/// passed by a run with no mutant on on each. A run whose simulators can't be made, booted or checked deletes them, and
/// tests one mutant at a time on its own destination, as with one worker, saying why. Every simulator made is deleted
/// once the work has ended, however it ended (`InterruptionRecord.afterWorkEnds`), or else by the next run's sweep.
struct SimulatorWorkerSetup {
    @Dependency(\.workerSimulators)
    private var workerSimulators: WorkerSimulating
    @Dependency(\.interruption)
    private var interruption: InterruptionRecord
    @Dependency(\.ioDelegate)
    private var ioDelegate: MutationTestingIODelegate
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    /// The simulators made for a run's workers, in worker order, or why it has none though it was to have some.
    struct Simulators: Sendable {
        var made: [WorkerSimulator] = []
        var unavailable: String?
    }

    /// The workers that test a run's mutants once its baseline has passed.
    struct Workers {
        /// How many test mutants at once.
        let count: Int
        /// Why the run tests one mutant at a time though it was to have simulators, or nil.
        let unavailable: String?
        /// The effective configuration, with failed-test lines unreliable if a check run printed a line that looks
        /// like a failed test or a crash.
        let configuration: MuterConfiguration
    }

    /// Makes a simulator like the one the run's first `-destination` names for each worker that is to test the
    /// `mutantsToTest` at once, when the run is an xcodebuild run that is to have more than one, and that destination
    /// is a simulator; none otherwise. Throws only a CancellationError.
    func make(for mutantsToTest: Int, state: AnyMutationTestState) async throws -> Simulators {
        let configuration = state.muterConfiguration
        let count = min(configuration.workerCount, mutantsToTest)
        guard configuration.buildSystem == .xcodebuild,
              count > 1,
              configuration.parallelWorkersUnsupportedReason == nil,
              let destination = configuration.firstDestination
        else {
            return Simulators()
        }
        // Before the first is made: `prepare` records each as simctl makes it, so a stop meanwhile leaves them to this.
        // It isn't cleared when mutation testing ends, which the work outlasts only by the report.
        interruption.afterWorkEnds { [workerSimulators] in await workerSimulators.removeAll() }
        do {
            let mutatedProject = state.mutatedProjectDirectoryURL
            return try await Simulators(made: workerSimulators.prepare(count, like: destination, for: mutatedProject))
        } catch let unavailable as WorkerSimulatorsUnavailable {
            return Simulators(unavailable: unavailable.reason)
        }
    }

    /// Boots `simulators`, all at once, and returns them once each has booted, or, once they are deleted, why one
    /// didn't. Throws only a CancellationError: a boot that a stop cut short leaves them to
    /// `InterruptionRecord.afterWorkEnds`, and the run is stopped, not tested one mutant at a time.
    static func boot(_ simulators: Simulators, on workerSimulators: WorkerSimulating) async throws -> Simulators {
        guard !simulators.made.isEmpty else {
            return simulators
        }
        do {
            try await workerSimulators.boot(simulators.made)
            return simulators
        } catch let unavailable as WorkerSimulatorsUnavailable {
            await workerSimulators.removeAll()
            return Simulators(unavailable: unavailable.reason)
        }
    }

    /// The workers that test the `planned` mutants at once, once the baseline has passed, with `configuration`, the
    /// effective one: one each on `simulators`, if there are any, else the `planned` as before. Each simulator first
    /// runs the tests with no mutant on, all at once, from its worker's `.xctestrun`, with its worker's arguments and
    /// no time limit, which keeps its first install and launch out of any mutant's time limit, and shows that the
    /// tests pass on it one at a time. A failed run keeps its log, and the run then tests one mutant at a time; every
    /// run's log is kept, and any that prints a line that looks like a failed test or a crash makes such lines
    /// unreliable, as the baseline's does. The workers are kept in `session` before their runs start, so their files
    /// are removed however mutation testing ends. `testOutput` names the file a run with the given log name writes to.
    /// A stop before the workers are known throws a CancellationError, as one during the baseline does, rather than
    /// being why the run tests one mutant at a time.
    func workers(
        _ planned: Int,
        on simulators: Simulators,
        configuration: MuterConfiguration,
        state: AnyMutationTestState,
        session: TestingSession,
        testOutput: (String) -> String
    ) async throws -> Workers {
        // A stop while the simulators that failed to boot were deleted, which `boot` doesn't see.
        try Task.checkCancellation()
        guard !simulators.made.isEmpty else {
            let count = simulators.unavailable == nil ? planned : 1
            return Workers(count: count, unavailable: simulators.unavailable, configuration: configuration)
        }
        let xcodeWorkers = simulators.made.enumerated().map { worker, simulator in
            MuterConfiguration.XcodeWorker(
                testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: worker),
                derivedData: MuterConfiguration.XcodeWorker.derivedData(
                    ofWorker: worker,
                    in: state.mutatedProjectDirectoryURL
                ),
                destination: simulator.destination,
                parallelTestingOff: true,
                testDiagnosticsOff: state.testDiagnosticsCanBeTurnedOff
            )
        }
        session.xcodeWorkers = xcodeWorkers
        let runs = await checkRuns(
            on: xcodeWorkers, configuration: configuration, state: state, testOutput: testOutput
        )
        // Stopping the run kills these runs too, which then fail, but that says nothing about the simulators.
        try Task.checkCancellation()
        let logs = runs.map { run in
            fileManager.keepLog(run.testLog, named: Self.checkRunLogName(ofWorker: run.worker), state: state)
        }

        // The lowest-numbered failure, so the same worker is named whichever run finished first.
        if let failed = runs.first(where: { $0.outcome != .passed }) {
            await workerSimulators.removeAll()
            // A stop while they were deleted.
            try Task.checkCancellation()
            let why = SimulatorTrouble.first(inLog: failed.testLog).map { ": \($0.line)" } ?? ""
            let log = logs[failed.worker] == nil ? "" : " (its log is \(Self.checkRunLogName(ofWorker: failed.worker)))"
            let reason = "worker \(failed.worker)'s run with no mutant on, on its simulator, didn't pass\(why)\(log)"
            return Workers(count: 1, unavailable: reason, configuration: configuration)
        }
        let lookalikes = runs.compactMap { run in
            FailedTestLine.first(inLog: run.testLog) ?? CrashLine.first(inLog: run.testLog)
        }
        return Workers(
            count: xcodeWorkers.count,
            unavailable: nil,
            configuration: lookalikes.isEmpty ? configuration : configuration.withUnreliableFailedTestLines()
        )
    }

    /// The name of the log of xcodebuild worker `worker`'s run with no mutant on.
    static func checkRunLogName(ofWorker worker: Int) -> String {
        "no-mutant run worker \(worker).log"
    }

    /// Runs the tests with no mutant on, on every one of `xcodeWorkers` at once, each from its own `.xctestrun`, and
    /// returns the runs in worker order. A worker whose `.xctestrun` can't be written fails its run.
    private func checkRuns(
        on xcodeWorkers: [MuterConfiguration.XcodeWorker],
        configuration: MuterConfiguration,
        state: AnyMutationTestState,
        testOutput: (String) -> String
    ) async -> [(worker: Int, outcome: TestSuiteOutcome, testLog: String)] {
        let (testRun, mutatedProject) = (state.projectXCTestRun, state.mutatedProjectDirectoryURL)
        let runs = await withTaskGroup(of: (worker: Int, outcome: TestSuiteOutcome, testLog: String).self) { group in
            for (worker, xcodeWorker) in xcodeWorkers.enumerated() {
                let configuration = configuration.forXcodeWorker(xcodeWorker)
                let fileName = testOutput("no-mutant run worker \(worker)")
                // A worker's run is given the values and the dependency it uses, not the setup or the state.
                group.addTask { [ioDelegate] in
                    do {
                        try await ioDelegate.switchOn(
                            schemata: .null, for: testRun, at: mutatedProject, named: xcodeWorker.testRunFile
                        )
                    } catch {
                        let why = error.localizedDescription
                        return (worker, .buildError, "SwiftMutator could not write \(xcodeWorker.testRunFile): \(why)")
                    }
                    let run = await ioDelegate.runTestsWithoutBuilding(
                        using: configuration,
                        savingResultsIntoFileNamed: fileName
                    )
                    return (worker, run.outcome, run.testLog)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        return runs.sorted { $0.worker < $1.worker }
    }
}
