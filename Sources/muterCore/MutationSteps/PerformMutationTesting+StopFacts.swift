/// What decides whether an xcodebuild run's mutants stop at their first failed test that the configuration file
/// doesn't hold, and the notice when a worker's run turns stopping off.
extension PerformMutationTesting {
    /// `state`'s configuration with the facts that decide whether an xcodebuild run's mutants can stop at their first
    /// failed test and that aren't configuration keys: which of the `.xctestrun`'s UI test targets the runs test
    /// (`MuterConfiguration.uiTestTargets`), whether a run on the test command's destination tests in parallel
    /// (`MuterConfiguration.destinationRunsInParallel`), and, for a first `-destination` that names a simulator by its
    /// `id=` or `name=` alone, without a platform, whether simctl lists it
    /// (`MuterConfiguration.firstDestinationIsASimulator`). Looked up only when they can matter: not for another build
    /// system, nor with `stopAtFirstFailure: false`. Whether a Mac's tests run unhosted, which decides it there too, is
    /// `withEveryStopFact(_:)`'s to add (`MuterConfiguration.withMacWorkerFact(given:)`), as it decides the Mac's
    /// workers as well.
    func withStopFacts(_ state: AnyMutationTestState) async -> MuterConfiguration {
        let configuration = state.muterConfiguration
        guard configuration.buildSystem == .xcodebuild, configuration.stopAtFirstFailure != .disabled else {
            return configuration
        }
        var listed = false
        if let destination = configuration.firstDestination,
           let simulator = SimulatorDestination(destination: destination),
           simulator.platform == nil {
            listed = await workerSimulators.listsASimulator(namedBy: destination)
        }
        return configuration.withStopFacts(
            firstDestinationIsASimulator: listed,
            uiTestTargets: configuration.targetsTested(among: state.projectXCTestRun.uiTestTargets),
            destinationRunsInParallel: configuration.destinationRunsInParallel(given: state.projectXCTestRun)
        )
    }

    /// `state`'s configuration with every fact that decides whether its mutants' runs stop at their first failed test
    /// before the workers are known: `withStopFacts(_:)`'s, and whether a Mac's tests run unhosted. Both a session that
    /// tests and one that kept every result write their header with it, so the two say the same.
    func withEveryStopFact(_ state: AnyMutationTestState) async -> MuterConfiguration {
        await withStopFacts(state).withMacWorkerFact(given: state.projectXCTestRun)
    }

    /// Says that stopping at the first failed test is off when `stopAtFirstFailure: true` asked for it, and the runs
    /// with `before`, the configuration before the first xcodebuild worker was known, would have stopped, but those on
    /// that worker, with `configuration`, can't: a lone worker on the test command's destination that tests in parallel
    /// (`MuterConfiguration.destinationRunsInParallel`). The notice as mutation testing starts can't know the workers.
    func sayWhetherTheFirstWorkerTurnedStoppingOff(_ configuration: MuterConfiguration, before: MuterConfiguration) {
        guard configuration.stopAtFirstFailure == .enabled,
              before.stopsAtFirstFailure,
              let reason = configuration.stopAtFirstFailureUnsupportedReason
        else { return }
        events.send(.stopAtFirstFailureTurnedOff(reason: reason))
    }

    /// Says that stopping at the first failed test is off when `workers`' check runs, one on each worker,
    /// printed a line that looks like a failed test or a crash, though the mutants' runs on those workers would have
    /// stopped with `configuration`, the one before the check runs. As a passing baseline's such line does
    /// (`mutantConfiguration`), before the baseline's log starts the progress bar or lines.
    func sayWhetherCheckRunsTurnedStoppingOff(
        _ workers: SimulatorWorkerSetup.Workers,
        configuration: MuterConfiguration
    ) {
        guard let lookalike = workers.lookalike,
              let worker = workers.xcodeWorkers.first,
              configuration.forXcodeWorker(worker).stopsAtFirstFailure
        else { return }
        let reason = "a worker's run with no mutant on passed but printed a line that looks like a failed test or a "
            + "crash:\n  " + lookalike
        events.send(.stopAtFirstFailureTurnedOff(reason: reason))
    }
}
