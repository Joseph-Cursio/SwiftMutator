import Foundation

/// What a session does with whether its mutants' blocks ran (`TestRun.activated`).
extension PerformMutationTesting {
    /// Keeps what `finished`, a mutant's first run, showed of its block, and stops mutation testing once
    /// `buildErrorsThreshold` runs, and none before them, show anything, where a run should: a `swift test` run, of
    /// mutants that coverage says the tests reach. Nothing else lets it conclude that: without coverage, the tests may
    /// reach no mutant; under xcodebuild, the test host may be unable to write; and a test plan's code may be an older
    /// SwiftMutator's, which writes no marker. Those only say so, after the mutants' runs.
    func noteActivation(
        in finished: FinishedRun,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) throws {
        let run = finished.run
        guard run.outcome != .buildError else { return }
        if run.activated != nil { session.activationShown = true }
        if run.activated == nil { session.runsShowingNoActivation += 1 }
        if run.activated != true {
            if [.failed, .runtimeError].contains(run.outcome) {
                session.killsNotShownToRunTheirCode.append(finished.index)
            }
            if run.outcome == .timeout { session.timeoutsNotShownToRunTheirCode.append(finished.index) }
        }
        guard !session.activationShown,
              session.runsShowingNoActivation >= buildErrorsThreshold,
              configuration.buildSystem == .swift,
              state.projectCoverage != .null,
              state.runOptions.testPlanURL == nil,
              state.selectedMutant == nil
        else { return }
        throw MuterError.mutationTestingAborted(
            reason: .noMutantCodeShownRunning(runs: session.runsShowingNoActivation)
        )
    }

    /// Says whether this session's runs could show their mutants' blocks ran, then tests again, one at a time on
    /// `worker`, those that failed without showing it: a flaky test or a crash at launch may have failed them, and this
    /// run decides. Each run's line replaces the first's. A session none of whose runs showed anything tests none
    /// again: a test host that can't write its marker would fail them just as before. Nor does `--mutant`'s, which has
    /// already given its verdict, and whose log shows it. A timeout is tested again only with `includingTimeouts`;
    /// otherwise `rerunTimeouts` has.
    func rerunRunsNotShownToReachTheirCode(
        of jobs: [MutantJob],
        on worker: PoolWorker,
        includingTimeouts: Bool,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        guard state.selectedMutant == nil else { return }
        guard session.activationShown else {
            if session.runsShowingNoActivation > 0 {
                events.send(.activationNotShown(runs: session.runsShowingNoActivation))
            }
            return
        }
        let timeouts = includingTimeouts ? session.timeoutsNotShownToRunTheirCode : []
        let indices = (session.killsNotShownToRunTheirCode + timeouts).sorted()
        guard !indices.isEmpty else { return }
        try Task.checkCancellation()
        events.send(.unprovenRunsRerunStarted(count: indices.count))
        var tally = UnprovenRunTally()
        try await runPool(
            indices.map(PoolTask.mutant),
            of: jobs,
            on: [worker],
            switchingOnFrom: state.projectXCTestRun,
            outputNamed: { testOutput(named: logFileName(forRerunOfJobAt: $0, $1), state: state) },
            recording: { finished in
                // The session shows runs can say, so a run that says nothing didn't reach mutated code.
                var settled = finished
                settled.run.activated = finished.run.activated ?? false
                let first = session.outcomes[finished.index]?.testSuiteOutcome
                let (outcome, _) = try keep(
                    settled,
                    of: jobs[finished.index],
                    rerun: MutantResult.Rerun(because: MutantResult.Rerun.codeNotShownRunning, workers: 1),
                    using: state,
                    configuration: configuration,
                    session: session
                )
                tally.add(outcome)
                events.send(.unprovenRunRerun(outcome, changed: outcome.testSuiteOutcome != first))
            }
        )
        events.send(.unprovenRunsRerunFinished(tally))
    }
}
