import Foundation

/// What those runs came to, so far.
struct SuspectKillRerunTally: Equatable {
    /// Failed again, or crashed.
    private(set) var killed = 0
    private(set) var survived = 0
    private(set) var notCovered = 0
    /// Timed out or failed to build: their kills stand, and a later session may test them again.
    private(set) var unsettled = 0

    mutating func add(_ outcome: TestSuiteOutcome) {
        switch outcome {
        case .failed, .runtimeError: killed += 1
        case .passed: survived += 1
        case .noCoverage: notCovered += 1
        case .timeout, .buildError: unsettled += 1
        }
    }
}

/// The kills a session tests again alone, once every mutant is tested: those only suspect tests failed for. A test can
/// be suspect for failing for mutants in many files, which a broad test of the mutated code does too, so this run tells
/// them apart: a kill a test really makes fails again, and one a flaky test made mostly doesn't. Its line replaces the
/// first run's, unless it timed out or failed to build, which says nothing of the mutant.
struct SuspectKillReruns: Equatable {
    /// How many kills are tested again.
    let count: Int
    /// How many kills only suspect tests failed for are over `suspectKillReruns`, so aren't.
    let leftOut: Int
}

extension PerformMutationTesting {
    static let suspectBaselineLogName = "tests alone with no mutant on.log"

    /// How many times each suspect test is tested before any test is tested more, and so what can clear it.
    static let rerunsForEachSuspectTest = KillingTestSummary.failuresAloneThatClearATest

    /// The jobs, by index, a session tests again alone, and how many kills only suspect tests failed for are left out.
    /// `suspects` are the tests suspect by the rule, a control run or what they did alone, and those earlier reruns
    /// cleared, so that a test's being cleared early doesn't decide what the rest of a run tests. Up to `limit`, less
    /// those a resumed run's earlier sessions tested: every suspect test first gets `rerunsForEachSuspectTest`,
    /// counting those it had in earlier sessions, from the kills only suspects failed for and then, as a test those
    /// don't name enough can't be judged, from others that name it; the rest of the limit goes to kills only suspects
    /// failed for.
    /// Evenly spaced in job order each time, so no file's mutants take it all.
    ///
    /// Never a reused kill, which this run didn't test; one not in this session's build, with no switch to turn on, or
    /// that didn't run its code, as `rerunRunsNotShownToReachTheirCode` has tested those. Never one tested so already.
    static func suspectKillCandidates(
        in outcomes: [Int: MutationTestOutcome.Mutation],
        suspects: Set<FailedTestLine.TestIdentity>,
        limit: Int,
        notInTheBuild: Set<Int> = []
    ) -> (indices: [Int], leftOut: Int) {
        let eligible = outcomes.filter { index, mutation in
            !notInTheBuild.contains(index) && mutation.testSuiteOutcome == .failed && mutation.reusedFrom == nil
                && mutation.activated != false && mutation.rerun?.because != MutantResult.Rerun.onlySuspectTestsFailed
                && mutation.killingTests?.tests.isEmpty == false
        }
        func names(_ index: Int) -> Set<FailedTestLine.TestIdentity> {
            Set((eligible[index]?.killingTests?.tests ?? []).map(FailedTestLine.TestIdentity.init))
        }
        let onlySuspects = eligible.keys.sorted().filter { names($0).isSubset(of: suspects) }
        let others = eligible.keys.sorted().filter { index in
            !names(index).isDisjoint(with: suspects) && !names(index).isSubset(of: suspects)
        }

        let tested = outcomes.values.filter(\.wasTestedAlone)
        let budget = max(0, limit - tested.count)
        var picked: [Int] = []
        func pick(_ indices: [Int], upTo count: Int) {
            let open = indices.filter { !picked.contains($0) }
            picked += evenlySpaced(open, count: min(count, budget - picked.count))
        }
        for test in suspects.sorted() {
            func stillOwed() -> Int {
                rerunsForEachSuspectTest
                    - tested.count { $0.rerun?.alone?.contains { $0.identity == test } == true }
                    - picked.count { names($0).contains(test) }
            }
            pick(onlySuspects.filter { names($0).contains(test) }, upTo: stillOwed())
            pick(others.filter { names($0).contains(test) }, upTo: stillOwed())
        }
        pick(onlySuspects, upTo: budget - picked.count)
        return (picked.sorted(), onlySuspects.count { !picked.contains($0) })
    }

    /// `count` of `items`, spread evenly over them, in their order.
    static func evenlySpaced<Item>(_ items: [Item], count: Int) -> [Item] {
        guard count > 0, !items.isEmpty else { return [] }
        guard count < items.count else { return items }
        return (0 ..< count).map { items[$0 * items.count / count] }
    }

    /// What `run`, a mutant tested again alone, says of each test that failed for it first. A test its log shows
    /// failing failed, unless the mutant's code didn't run, by `activated`, or by saying nothing in a session whose
    /// runs can say. One it doesn't show passed only if the run ran every test: it exited by itself with no crash, as
    /// a crash can end a test process before a test ever ran, and if it failed, it names what failed. There is no line
    /// to look for
    /// instead, as `swift test --quiet` prints no line for a test that passes. A failure by another test of the same
    /// name says nothing. `lookalikes` are lines a test prints whatever the mutant, as `configuration` has them.
    static func testsAlone(
        _ first: [FailedTestLine.FailedTest],
        in run: TestRun,
        ignoring lookalikes: Set<FailedTestLine.TestIdentity> = [],
        sessionShowsActivation: Bool = false
    ) -> [MutantResult.Rerun.TestAlone] {
        let failed = FailedTestLine.failedTestIdentities(inLog: run.testLog).subtracting(lookalikes)
        let crash = CrashLine.first(inLog: run.testLog)
        let reachedItsEnd = run.ending == .exited && crash == nil
        let saysWhatFailed = run.outcome == .passed || run.outcome == .failed && !failed.isEmpty
        let ranEveryTest = reachedItsEnd && saysWhatFailed
        let codeDidntRun = run.activated == false || run.activated == nil && sessionShowsActivation
        return first.map { test in
            let identity = FailedTestLine.TestIdentity(test)
            let result: String? = if failed.contains(identity) {
                codeDidntRun
                    ? MutantResult.Rerun.TestAlone.failedWithItsCodeNotRunning
                    : MutantResult.Rerun.TestAlone.failedAgain
            } else if failed.contains(where: { $0.name == identity.name }) {
                nil
            } else {
                ranEveryTest ? MutantResult.Rerun.TestAlone.passed : nil
            }
            return .init(name: identity.name, file: identity.file, result: result)
        }
    }

    /// Tests this session's kills only suspect tests failed for again, one at a time on `worker`, each run going to its
    /// end so it says which tests fail. Nothing for `--mutant`'s one mutant, with `suspectKillReruns` 0, or with no
    /// such kill. First the tests run once alone with no mutant on: if they don't pass, a failure with a mutant on says
    /// nothing of the mutant, so no kill is tested again, and that is said.
    func rerunSuspectKills(
        of jobs: [MutantJob],
        on worker: PoolWorker,
        from testRun: XCTestRun,
        in context: RunContext
    ) async throws {
        guard context.state.selectedMutant == nil, context.configuration.killsToTestAgainAlone > 0,
              let summary = KillingTestSummary(
                  of: context.session.outcomesInJobOrder,
                  controlRuns: Self.controlRuns(of: context.session, state: context.state),
                  thresholds: context.state.muterConfiguration.suspectTestThresholds
              )
        else { return }
        let (indices, leftOut) = Self.suspectKillCandidates(
            in: context.session.outcomes,
            suspects: summary.suspectsWhateverTheyDidAlone,
            limit: context.configuration.killsToTestAgainAlone,
            notInTheBuild: context.session.notInTheBuild
        )
        guard !indices.isEmpty else { return }
        try Task.checkCancellation()
        let alone = PoolWorker(directory: worker.directory, configuration: worker.configuration.goingToEachRunsEnd())

        guard try await suspectBaselinePassed(on: alone, from: testRun, in: context) else { return }

        events.send(.suspectKillRerunsStarted(SuspectKillReruns(count: indices.count, leftOut: leftOut)))
        var tally = SuspectKillRerunTally()
        try await runPool(
            PoolWork(tasks: indices.map(PoolTask.mutant), jobs: jobs, testRun: testRun),
            on: [alone],
            outputNamed: { testOutput(named: logFileName(forRerunOfJobAt: $0, $1), state: context.state) },
            recording: { finished in
                try recordSuspectKillRerun(
                    finished,
                    of: jobs[finished.index],
                    tally: &tally,
                    in: context.with(alone.configuration)
                )
            }
        )
        events.send(.suspectKillRerunsFinished(tally))
    }

    /// Whether the tests, run alone on `alone` with no mutant on, from `testRun`, pass, as the suspect kills' reruns
    /// need. Its log is kept, and one that fails says the reruns are skipped.
    private func suspectBaselinePassed(
        on alone: PoolWorker,
        from testRun: XCTestRun,
        in context: RunContext
    ) async throws -> Bool {
        let baseline = try await Self.runControl(
            0,
            on: (0, alone),
            at: (alone.directory, testOutput(named: Self.suspectBaselineLogName, state: context.state)),
            from: testRun,
            using: runDependencies
        )
        try Self.throwIfCancelled(baseline.run)
        try abortingIfTheSimulatorIsGone(
            in: baseline,
            logName: Self.suspectBaselineLogName,
            configuration: alone.configuration,
            state: context.state
        )
        if let failure = baseline.launchFailure {
            fileManager.keepLog(
                failure.testLog,
                named: MutationTestLog.launchFailedFileName(for: Self.suspectBaselineLogName),
                state: context.state
            )
        }
        let log = fileManager.keepLog(
            baseline.run.testLog,
            writtenTo: baseline.output,
            by: ioDelegate,
            named: Self.suspectBaselineLogName,
            state: context.state
        )
        guard baseline.run.outcome == .passed else {
            events.send(.suspectKillRerunsSkipped(log: log.map { _ in Self.suspectBaselineLogName }))
            return false
        }
        return true
    }

    /// Records `finished`, a kill tested again alone, in place of its first run, with what it says of the tests that
    /// failed then, which its line would otherwise lose, counts it in `tally`, and sends it. A run that timed out or
    /// failed to build says nothing of the mutant: it replaces nothing, and only its log is kept, so the kill stands.
    /// `activated` is whichever run showed the block ran, as `recordRerun`'s, but says nothing it doesn't know: a
    /// session that can't show it must not read as one that can, or a flip would read as not covered.
    private func recordSuspectKillRerun(
        _ finished: FinishedRun,
        of job: MutantJob,
        tally: inout SuspectKillRerunTally,
        in context: RunContext
    ) throws {
        let first = context.session.outcomes[finished.index]
        guard ![.timeout, .buildError].contains(finished.run.outcome) else {
            let name = MutationTestLog.suspectRerunFileName(for: context.session.keys[finished.index])
            try abortingIfTheSimulatorIsGone(
                in: finished,
                logName: name,
                configuration: context.configuration,
                state: context.state
            )
            if let failure = finished.launchFailure {
                fileManager.keepLog(
                    failure.testLog, named: MutationTestLog.launchFailedFileName(for: name), state: context.state
                )
            }
            fileManager.keepLog(
                finished.run.testLog,
                writtenTo: finished.output,
                by: ioDelegate,
                named: context.state.loggingDirectory.isEmpty ? nil : name,
                state: context.state
            )
            tally.add(finished.run.outcome)
            return
        }
        var settled = finished
        if first?.activated == true { settled.run.activated = true }
        let (outcome, _) = try keep(
            settled,
            of: job,
            rerun: MutantResult.Rerun(
                because: MutantResult.Rerun.onlySuspectTestsFailed,
                workers: 1,
                alone: Self.testsAlone(
                    first?.killingTests?.tests ?? [],
                    in: finished.run,
                    ignoring: context.configuration.failedTestLookalikes,
                    sessionShowsActivation: context.session.activationShown
                )
            ),
            in: context
        )
        tally.add(outcome.testSuiteOutcome)
        events.send(.suspectKillRerun(outcome, changed: outcome.testSuiteOutcome != first?.testSuiteOutcome))
    }
}
