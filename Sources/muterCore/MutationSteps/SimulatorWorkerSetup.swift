import Foundation

/// Gives each worker of an xcodebuild run whose first `-destination` is a simulator a simulator of its own, worker 0's
/// included: made like the destination's before the baseline, booted while the baseline runs, and checked once it has
/// passed by a run with no mutant on on each. A lone worker gets one too when that should be faster
/// (`oneWorkerPlan(for:state:)`), and the run can then delete it before its check, once the baseline shows it
/// wouldn't be (`reasonToDropTheOneWorkerSimulator(_:)`). A run whose simulators can't be made, booted or checked
/// deletes them, and tests one mutant at a time on its own destination, as with one worker, saying why. Every simulator
/// made is deleted once the work has ended, however it ended (`InterruptionRecord.afterWorkEnds`), or else by the next
/// run's sweep.
struct SimulatorWorkerSetup {
    @Dependency(\.workerSimulators)
    private var workerSimulators: WorkerSimulating
    @Dependency(\.interruption)
    private var interruption: InterruptionRecord
    @Dependency(\.ioDelegate)
    private var ioDelegate: MutationTestingIODelegate
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.instant)
    private var instant: Instant

    /// The fewest mutants for which one worker gets a simulator of its own unless `oneWorkerSimulator` says: its make,
    /// boot and check run cost about 90 s at worst, and each mutant's run then saves about 15 s.
    static let minimumMutantsForOneWorkerSimulator = 6

    /// A run on the test command's destination under parallel testing pays a clone and a boot of about 15 s (22 s
    /// against 7 s measured) on top of its tests' seconds spread over the clones, S / K. A suite whose tests add up to
    /// no more than this many seconds is then faster one test at a time, on a simulator of its own, on any number of
    /// clones.
    static let serialTestSecondsAlwaysFaster: TimeInterval = 10

    /// The simulators made for a run's workers, in worker order, or why it has none though it was to have some.
    struct Simulators: Sendable {
        var made: [WorkerSimulator] = []
        var unavailable: String?
        /// Whether the baseline decides whether to keep a lone worker's simulator, before its check run
        /// (`checkedAgainstTheBaseline(_:log:)`).
        var checkedAgainstBaseline = false
    }

    /// Whether a run that is to test on one worker gets a simulator of its own, before its baseline.
    enum OneWorkerPlan: Equatable {
        /// It tests on the test command's destination, saying nothing.
        case noSimulator
        /// It tests on the test command's destination, saying why: the reason, completing "Testing one mutant at a
        /// time on the test command's destination: …".
        case declined(String)
        /// It gets one, and keeps it unless, if `checkedAgainstBaseline`, the baseline shows it wouldn't be faster.
        case simulator(checkedAgainstBaseline: Bool)
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
        /// The workers the mutants run on, each on its simulator, once their check runs have passed; none when the run
        /// tests on the test command's destination, after a fallback too. `TestingSession.xcodeWorkers` is set before
        /// the check runs, and never cleared, so that the workers' files are removed however the run ends: after a
        /// fallback it still names simulators that were deleted, so no worker may be picked from it.
        let xcodeWorkers: [MuterConfiguration.XcodeWorker]
        /// How long the longest of their runs with no mutant on took, from its start to its outcome, with the run
        /// before it if the simulator failed to launch that one; none when they test on the test command's
        /// destination. A run tests one test at a time, as a mutant's does on its worker, and its first install and
        /// launch only make it longer.
        var checkRunSeconds: TimeInterval?
    }

    /// `simulators`, unless the run is to check its lone worker's against `baselineLog`, the passing baseline's, and
    /// that shows they wouldn't be faster (`reasonToDropTheOneWorkerSimulator(_:)`) on `destination`, the test
    /// command's first: it is then deleted, before its check run, and the run tests on that destination, saying why.
    /// A stop while it is deleted throws a CancellationError.
    func checkedAgainstTheBaseline(
        _ simulators: Simulators,
        log baselineLog: String,
        destination: String?
    ) async throws -> Simulators {
        let device = destination.flatMap { SimulatorDestination(destination: $0)?.name }
        guard simulators.checkedAgainstBaseline,
              !simulators.made.isEmpty,
              let why = Self.reasonToDropTheOneWorkerSimulator(
                  ParallelTestingSpread.of(baselineLog: baselineLog, onDeviceNamed: device)
              )
        else {
            return simulators
        }
        await workerSimulators.removeAll()
        try Task.checkCancellation()
        return Simulators(unavailable: why)
    }

    /// Why a lone worker's simulator wouldn't be faster than the test command's destination, given `spread`, the
    /// baseline's, or nil when it would be. It would when the baseline tested on one clone, as a mutant's run on the
    /// destination would, paying the clone and boot that a simulator of its own doesn't, or when its tests take no
    /// more than `serialTestSecondsAlwaysFaster`. A baseline that printed no line for a test on a clone shows neither.
    static func reasonToDropTheOneWorkerSimulator(_ spread: ParallelTestingSpread?) -> String? {
        guard let spread else {
            return "the baseline printed no parallel testing line to tell how many clones its tests ran on; "
                + "`oneWorkerSimulator: true` tests on a simulator of its own anyway"
        }
        guard spread.clones > 1, spread.testSeconds > serialTestSecondsAlwaysFaster else {
            return nil
        }
        let seconds = String(format: "%.1f", spread.testSeconds)
        return "the baseline's parallel testing spread \(seconds) s of tests over \(spread.clones) clones, which one "
            + "at a time on one simulator could make slower; `oneWorkerSimulator: true` tests on one anyway"
    }

    /// Whether a run that is to test its `mutantsToTest` on one worker gets a simulator of its own: only an xcodebuild
    /// run with 2 mutants or more that wasn't asked for more workers, with `oneWorkerSimulator` not false, and neither
    /// `--mutant` nor a first `-destination` that isn't a simulator. With `oneWorkerSimulator` true, that is all; a
    /// destination that isn't a simulator is then said. Otherwise only when it should be faster: with 6 mutants or
    /// more, and parallel testing on for a mutant's run on the destination, which then clones and boots its simulator:
    /// on in the `.xctestrun` (`XCTestRun.parallelizes`), unless the test command's arguments turn it off, or on in
    /// them. They reach such a run as they reach the baseline, so the baseline then decides whether to keep it
    /// (`reasonToDropTheOneWorkerSimulator(_:)`), whatever else they tune.
    static func oneWorkerPlan(for mutantsToTest: Int, state: AnyMutationTestState) -> OneWorkerPlan {
        let configuration = state.muterConfiguration
        let wanted = configuration.oneWorkerSimulator
        guard configuration.buildSystem == .xcodebuild,
              (configuration.mutationTestWorkers ?? 1) <= 1,
              wanted != false,
              state.selectedMutant == nil,
              mutantsToTest >= 2
        else {
            return .noSimulator
        }
        guard configuration.parallelWorkersUnsupportedReason == nil, configuration.firstDestination != nil else {
            return wanted == true
                ? .declined("a simulator of its own needs a first `-destination` that is a simulator")
                : .noSimulator
        }
        if wanted == true {
            return .simulator(checkedAgainstBaseline: false)
        }
        let parallelizes = switch configuration.parallelTestingArguments {
        case .unset: state.projectXCTestRun.parallelizes
        case .enabled: true
        case .disabled: false
        }
        guard mutantsToTest >= minimumMutantsForOneWorkerSimulator, parallelizes else {
            return .noSimulator
        }
        return .simulator(checkedAgainstBaseline: true)
    }

    /// Makes a simulator like the one the run's first `-destination` names for each worker that is to test the
    /// `mutantsToTest` at once, when the run is an xcodebuild run that is to have more than one, and that destination
    /// is a simulator, or for its lone worker, as `oneWorkerPlan(for:state:)` says; none otherwise. A lone worker's
    /// destination that names no one simulator is said only if `oneWorkerSimulator` asked for one. Throws only a
    /// CancellationError.
    func make(for mutantsToTest: Int, state: AnyMutationTestState) async throws -> Simulators {
        let configuration = state.muterConfiguration
        let count = min(configuration.workerCount, mutantsToTest)
        var checkedAgainstBaseline = false
        if count <= 1 {
            switch Self.oneWorkerPlan(for: mutantsToTest, state: state) {
            case .noSimulator:
                return Simulators()
            case let .declined(why):
                return Simulators(unavailable: why)
            case let .simulator(checked):
                checkedAgainstBaseline = checked
            }
        }
        guard configuration.buildSystem == .xcodebuild,
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
            return try await Simulators(
                made: workerSimulators.prepare(count, like: destination, for: mutatedProject),
                checkedAgainstBaseline: checkedAgainstBaseline
            )
        } catch let unavailable as WorkerSimulatorsUnavailable {
            if count == 1, unavailable.destinationUnresolved, configuration.oneWorkerSimulator == nil {
                return Simulators()
            }
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
    /// no mutant's time limit, only `buildTimeout`'s, which keeps its first install and launch out of any mutant's
    /// time limit, and shows that the
    /// tests pass on it one at a time. A run the simulator failed to launch runs once more in its place, as a mutant's
    /// does, and its log is kept beside the second's. A failed run keeps its log, and the run then tests one mutant at
    /// a time; every run's log is kept, and any that prints a line that looks like a failed test or a crash makes such
    /// lines unreliable, as the baseline's does. The workers are kept in `session` before their runs start, so their
    /// files are removed however mutation testing ends, but the mutants run only on the workers returned, which are
    /// none after a fallback (`Workers.xcodeWorkers`). `testOutput` names the file a run with the given log name
    /// writes to. A stop before the workers are known throws a CancellationError, as one during the baseline does,
    /// rather than being why the run tests one mutant at a time.
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
            return Workers(
                count: count, unavailable: simulators.unavailable, configuration: configuration, xcodeWorkers: []
            )
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
            let logName = Self.checkRunLogName(ofWorker: run.worker)
            if let failure = run.launchFailure {
                fileManager.keepLog(
                    failure.testLog, named: MutationTestLog.launchFailedFileName(for: logName), state: state
                )
            }
            return fileManager.keepLog(run.testLog, writtenTo: run.output, by: ioDelegate, named: logName, state: state)
        }

        // The lowest-numbered failure, so the same worker is named whichever run finished first.
        if let failed = runs.first(where: { $0.outcome != .passed || $0.timedOut }) {
            await workerSimulators.removeAll()
            // A stop while they were deleted.
            try Task.checkCancellation()
            let why = SimulatorTrouble.first(inLog: failed.testLog).map { ": \($0.line)" } ?? ""
            let log = logs[failed.worker] == nil ? "" : " (its log is \(Self.checkRunLogName(ofWorker: failed.worker)))"
            let ended = failed.timedOut
                ? "didn't end within \(String(format: "%g", configuration.buildTimeout ?? 0)) s (buildTimeout)"
                : "didn't pass\(why)"
            let reason = "worker \(failed.worker)'s run with no mutant on, on its simulator, \(ended)\(log)"
            return Workers(count: 1, unavailable: reason, configuration: configuration, xcodeWorkers: [])
        }
        // The logs of the runs that printed a line shaped like a failed test or a crash.
        let printingLookalikes = runs.compactMap { run in
            (FailedTestLine.first(inLog: run.testLog) ?? CrashLine.first(inLog: run.testLog)).map { _ in run.testLog }
        }
        return Workers(
            count: xcodeWorkers.count,
            unavailable: nil,
            configuration: printingLookalikes.isEmpty
                ? configuration : configuration.withUnreliableFailedTestLines(printedIn: printingLookalikes),
            xcodeWorkers: xcodeWorkers,
            checkRunSeconds: runs.map(\.seconds).max()
        )
    }

    /// The name of the log of xcodebuild worker `worker`'s run with no mutant on.
    static func checkRunLogName(ofWorker worker: Int) -> String {
        "no-mutant run worker \(worker).log"
    }

    /// A worker's run with no mutant on, the run before it, if the simulator failed to launch that one, how long both
    /// took, and the file it wrote its output to, none if it never ran.
    private struct CheckRun {
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
    private func checkRuns(
        on xcodeWorkers: [MuterConfiguration.XcodeWorker],
        configuration: MuterConfiguration,
        state: AnyMutationTestState,
        testOutput: (String) -> String
    ) async -> [CheckRun] {
        let (testRun, mutatedProject) = (state.projectXCTestRun, state.mutatedProjectDirectoryURL)
        let runs = await withTaskGroup(of: CheckRun.self) { group in
            for (worker, xcodeWorker) in xcodeWorkers.enumerated() {
                let configuration = configuration.forXcodeWorker(xcodeWorker)
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
                    let (run, launchFailure) = await TestRun.launchedOnceMore(ifNeededWith: configuration) {
                        await ioDelegate.runTestsWithoutBuilding(
                            using: configuration,
                            timeLimit: configuration.buildTimeout,
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
}
