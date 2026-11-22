import Foundation

/// Whether the simulators of a default count of xcodebuild workers, which neither `mutationTestWorkers` nor `--workers`
/// asked for, should be faster than one worker on the test command's destination.
extension SimulatorWorkerSetup {
    /// Whether the baseline decides whether to keep the simulators a run makes for more than one worker: only when
    /// `configuration` gives no `mutationTestWorkers`, so the count is SwiftMutator's own
    /// (`MuterConfiguration.defaultWorkerCount`), `oneWorkerSimulator: true` didn't ask for simulators whatever the
    /// baseline shows, and a mutant's run on the test command's destination tests in parallel, as `xctestrun`, the
    /// project's `.xctestrun`, or the test command's arguments say (`MuterConfiguration.destinationRunsInParallel`).
    /// Without parallel testing, that run tests one test at a time on one simulator, as each worker does on its own,
    /// so several such workers are faster whatever the baseline shows.
    static func checksTheDefaultSimulators(_ configuration: MuterConfiguration, given xctestrun: XCTestRun) -> Bool {
        configuration.mutationTestWorkers == nil
            && configuration.oneWorkerSimulator != .enabled
            && configuration.destinationRunsInParallel(given: xctestrun)
    }

    /// Why the `workers` simulators of a default count wouldn't be faster than one worker on the test command's
    /// destination, given `spread`, the baseline's, or nil when they would be (`simulatorsAreFaster(given:workers:)`).
    /// A baseline that printed no line for a test on a clone tested one test at a time, as a mutant's run on the
    /// destination then does, and as each worker does on its own simulator, so N of them, testing N mutants at once,
    /// are faster, as without parallel testing (`checksTheDefaultSimulators(_:given:)`). A lone worker gains nothing
    /// there (`reasonToDropTheOneWorkerSimulator(_:)`), but several do. A log that hides those lines keeps them too.
    static func reasonToDropTheDefaultSimulators(_ spread: ParallelTestingSpread?, workers: Int) -> String? {
        guard let spread, !simulatorsAreFaster(given: spread, workers: workers) else {
            return nil
        }
        let seconds = String(format: "%.1f", spread.testSeconds)
        return "the baseline's parallel testing spread \(seconds) s of tests over \(spread.clones) clones, which "
            + "\(workers) workers testing one at a time, each on a simulator of its own, could make slower; "
            + "`--workers \(workers)` tests on \(workers) simulators anyway"
    }

    /// How many workers test a run's mutants when it has no simulator for them: the `planned`, but 1 when
    /// `unavailable` says why it has none, and never more than 1 on `buildSystem` xcodebuild, whose run then tests on
    /// the test command's destination, as after a default count's quiet fallback (`make(for:state:)`).
    static func workersWithoutSimulators(planned: Int, unavailable: String?, buildSystem: BuildSystem) -> Int {
        guard unavailable == nil else {
            return 1
        }
        return buildSystem == .xcodebuild ? min(planned, 1) : planned
    }

    /// Whether `workers` workers, each testing one test at a time on a simulator of its own, should test mutants
    /// faster than one worker on the test command's destination under parallel testing, given `spread`, the baseline's
    /// there. A mutant's run on the destination pays a clone and a boot, more than `serialTestSecondsAlwaysFaster`, on
    /// top of its tests' S seconds spread over the baseline's K clones, S / K; N workers test N mutants at once, each
    /// in S seconds, so a mutant takes S / N of the run's time. They are faster when S / N is no more than
    /// `serialTestSecondsAlwaysFaster` + S / K, as the clone and boot alone take longer than that bound's first term:
    /// always when N is at least K, or when S / N is no more than `serialTestSecondsAlwaysFaster`, and for 2 workers
    /// with S up to 60 s on 3 clones, or 40 s on 4. Otherwise the destination could be faster, and it is chosen.
    /// One worker keeps the lone worker's rule, which counts only those two cases, K = 1 or S no more than
    /// `serialTestSecondsAlwaysFaster`, as it always has (`reasonToDropTheOneWorkerSimulator(_:)`).
    static func simulatorsAreFaster(given spread: ParallelTestingSpread, workers: Int) -> Bool {
        guard workers > 1 else {
            return spread.clones <= 1 || spread.testSeconds <= serialTestSecondsAlwaysFaster
        }
        let onSimulators = spread.testSeconds / Double(workers)
        let onTheDestination = serialTestSecondsAlwaysFaster + spread.testSeconds / Double(max(1, spread.clones))
        return onSimulators <= onTheDestination
    }
}
