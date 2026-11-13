/// What the property survivor reruns came to, so far.
struct PropertySurvivorRerunTally: Equatable {
    let reruns: PropertySurvivorReruns
    /// A property test failed, or the property tests crashed, on some run.
    private(set) var failed = 0
    /// Every run passed.
    private(set) var passed = 0
    /// A run timed out, or failed to build: it settles nothing.
    private(set) var unsettled = 0

    init(_ reruns: PropertySurvivorReruns) {
        self.reruns = reruns
    }

    var finished: Int {
        failed + passed + unsettled
    }

    mutating func add(_ rerun: MutationTestOutcome.PropertySurvivorRerun) {
        if rerun.failedOnRun != nil {
            failed += 1
        } else if rerun.passedEveryRun {
            passed += 1
        } else {
            unsettled += 1
        }
    }
}

/// The survivors a session tests again with only the property tests `propertyTestFilter` selects, once every mutant is
/// tested: each survivor whose code ran, up to `propertySurvivorReruns` times, stopping at the first run that doesn't
/// pass. A property test tries a sample of inputs, so a survivor may only have missed the one that tells it apart: a
/// failure on a later run says the law holds the change and the generator rarely reaches it, and every run passing
/// says the law doesn't reach it, or the mutant is equivalent. Neither proves equivalence. It never changes a mutant's
/// result: a survivor a property told apart stays a survivor in the score, `--fail-under` and `--baseline`.
struct PropertySurvivorReruns: Equatable {
    /// How many survivors are tested again.
    let count: Int
    /// How many times each is tested, at most.
    let runs: Int
    /// How many of them are tested at once.
    let workers: Int
    /// How many survivors whose code ran are over `propertySurvivorRerunLimit`, so aren't.
    let leftOut: Int
}

extension PerformMutationTesting {
    /// The jobs, by index in job order, whose survival this session tests again with the property tests, and how many
    /// such survivors are left out: each survivor whose code ran, or couldn't be shown not to, with no property
    /// survivor rerun yet. Up to `limit`, less those a resumed run's earlier sessions tested, evenly spaced in job
    /// order so no file's mutants take it all. Never one not in this session's build: with no switch to turn on, every
    /// property test would pass.
    static func propertySurvivorCandidates(in session: TestingSession, limit: Int) -> (indices: [Int], leftOut: Int) {
        let eligible = session.outcomes.keys.sorted().filter { index in
            guard let mutation = session.outcomes[index] else { return false }
            return !session.notInTheBuild.contains(index) && mutation.testSuiteOutcome == .passed
                && mutation.propertySurvivorRerun == nil && mutation.activated != .didNotRun
        }
        let tested = session.outcomes.values.count { $0.propertySurvivorRerun != nil }
        let picked = evenlySpaced(eligible, count: max(0, limit - tested))
        return (picked, eligible.count - picked.count)
    }

    /// Tests each of `candidates`, survivors, again with the property tests on `pool`, the workers' configurations
    /// already filtered to them, up to `propertySurvivorReruns` times: in rounds, each testing again those every run
    /// so far passed, so that no survivor's runs overlap. A survivor's line is written once its runs end: at the first
    /// that doesn't pass, or the last. It follows its mutant's line, which it never replaces.
    func rerunSurvivorsWithPropertyTests(
        _ candidates: (indices: [Int], leftOut: Int),
        of jobs: [MutantJob],
        on pool: [PoolWorker],
        from testRun: XCTestRun,
        in context: RunContext
    ) async throws {
        let runs = context.configuration.runsForEachSurvivor
        guard let first = pool.first, !candidates.indices.isEmpty, runs > 0 else { return }
        let reruns = PropertySurvivorReruns(
            count: candidates.indices.count,
            runs: runs,
            workers: min(pool.count, candidates.indices.count),
            leftOut: candidates.leftOut
        )
        events.send(.propertySurvivorRerunsStarted(reruns))
        var tally = PropertySurvivorRerunTally(reruns)
        var remaining = candidates.indices
        for run in 1 ... runs where !remaining.isEmpty {
            try Task.checkCancellation()
            var passedSoFar: [Int] = []
            try await runPool(
                PoolWork(tasks: remaining.map(PoolTask.mutant), jobs: jobs, testRun: testRun),
                on: Array(pool.prefix(min(pool.count, remaining.count))),
                outputNamed: { index, job in
                    testOutput(
                        named: logFileName(forPropertySurvivorRerunOfJobAt: index, job, run: run),
                        state: context.state
                    )
                },
                recording: { finished in
                    let ended = try recordPropertySurvivorRerun(
                        finished, run: run, of: runs, tally: &tally, in: context.with(first.configuration)
                    )
                    if !ended {
                        passedSoFar.append(finished.index)
                    }
                }
            )
            remaining = passedSoFar.sorted()
        }
        events.send(.propertySurvivorRerunsFinished(tally))
    }

    /// Takes `finished`, run `run` of `runs` of a survivor's property tests, and, if it ends the survivor's runs, as a
    /// run that didn't pass or the last one does, writes its line to the results file, keeps it in the mutant's outcome
    /// in `session`, counts it in `tally` and gives true. A run that passed before the last gives false, and its log
    /// is kept only with `keepAllLogs`; an ending run's log is kept unless every run passed, or a property test its
    /// line names failed, which its line says, or with `keepAllLogs`.
    func recordPropertySurvivorRerun(
        _ finished: FinishedRun,
        run: Int,
        of runs: Int,
        tally: inout PropertySurvivorRerunTally,
        in context: RunContext
    ) throws -> Bool {
        let key = context.session.keys[finished.index]
        let name = MutationTestLog.propertySurvivorRerunFileName(for: key, run: run)
        try abortingIfTheSimulatorIsGone(
            in: finished,
            logName: name,
            configuration: context.configuration,
            state: context.state
        )
        let failures = MutantResult.failedTests(of: finished.run, ignoring: context.configuration.failedTestLookalikes)
        let passed = finished.run.outcome == .passed
        let keeps = passed
            ? context.configuration.keepsAllLogs
            : MutationTestLog.isKept(
                outcome: finished.run.outcome, killedBy: failures?.tests, keepingAll: context.configuration.keepsAllLogs
            )
        let keptLog = keeps && !context.state.loggingDirectory.isEmpty ? name : nil
        fileManager.keepLog(
            finished.run.testLog, writtenTo: finished.output, by: ioDelegate, named: keptLog, state: context.state
        )
        guard !passed || run == runs else { return false }

        let record = PropertySurvivorRerunResult(
            key: key,
            finished: finished,
            run: run,
            of: runs,
            failures: failures,
            session: context.session.number,
            finishedAt: now(),
            log: keptLog
        )
        write(record, in: context.session)
        context.session.outcomes[finished.index]?.propertySurvivorRerun = record.rerun
        tally.add(record.rerun)
        return true
    }

    /// The file run `run` of a survivor's property reruns writes its output to while it runs, which no other run
    /// shares.
    func logFileName(forPropertySurvivorRerunOfJobAt index: Int, _ job: MutantJob, run: Int) -> String {
        "\(index)_properties_run\(run)_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_"
            + "\(job.schema.position).log"
    }
}
