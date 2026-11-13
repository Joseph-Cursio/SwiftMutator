import Foundation

/// What the property reruns came to, so far.
struct PropertyRerunTally: Equatable {
    let reruns: PropertyReruns
    private(set) var rerun = 0
    /// A property test failed, or the property tests crashed: a kill by both kinds.
    private(set) var killed = 0
    /// Every property test passed: a kill by examples alone.
    private(set) var passed = 0
    /// Timed out, or failed to build: it settles nothing.
    private(set) var unsettled = 0

    init(_ reruns: PropertyReruns) {
        self.reruns = reruns
    }

    mutating func add(_ rerun: MutationTestOutcome.PropertyRerun) {
        self.rerun += 1
        if rerun.killed {
            killed += 1
        } else if rerun.outcome == .passed {
            passed += 1
        } else {
            unsettled += 1
        }
    }
}

/// The kills a session tests again with only the property tests `propertyTestFilter` selects, once every mutant is
/// tested: those whose recorded tests include no property test, which `propertyTests` picks out. A run stopped at its
/// first failed test records that test alone, so an example that failed first hides a property that would also have
/// failed. This run tells "only by examples" from "by both". It never changes a mutant's result.
struct PropertyReruns: Equatable {
    /// How many kills are tested again.
    let count: Int
    /// How many of them are tested at once.
    let workers: Int
}

extension PerformMutationTesting {
    static let propertyBaselineLogName = "property tests with no mutant on.log"

    /// The jobs, by index in job order, whose kill this session tests again with the property tests alone: each a
    /// failed test killed, whose recorded tests include none `globs` match, and with no property rerun yet. A kill that
    /// names no test, such as a crash's, isn't: there is no example to tell it from. Nor is a kept kill whose mutant
    /// isn't in this session's build: with no switch to turn on, every property test would pass. Nor is a kill whose
    /// code didn't run, as they would pass then too.
    static func propertyRerunCandidates(in session: TestingSession, globs: [String]) -> [Int] {
        let patterns = globs.map(PropertyTestPattern.init)
        return session.outcomes.sorted { $0.key < $1.key }.compactMap { index, mutation in
            guard !session.notInTheBuild.contains(index), mutation.testSuiteOutcome == .failed,
                  mutation.propertyRerun == nil, mutation.activated != .didNotRun,
                  let tests = mutation.killingTests?.tests, !tests.isEmpty,
                  !tests.contains(where: { test in patterns.contains { $0.matches(.init(test)) } })
            else { return nil }
            return index
        }
    }

    /// Tests again, with only the tests `propertyTestFilter` selects, on `workers` at once and fail-fast as the
    /// mutants' runs have it: each of this session's kills whose recorded tests include no property test, once; then
    /// survivors whose code ran, up to `propertySurvivorReruns` times each (`rerunSurvivorsWithPropertyTests`).
    /// Nothing without a filter, for `--mutant`'s one mutant, or with nothing to test again. First the property tests
    /// run once with no mutant on: if they don't pass, or ran no test, as a filter that matches none would, nothing is
    /// tested again, as every rerun would mean nothing, and that is said. Each rerun's line follows its mutant's, which
    /// it never replaces.
    func rerunPropertyTests(
        of jobs: [MutantJob],
        on workers: [PoolWorker],
        from testRun: XCTestRun,
        in context: RunContext
    ) async throws {
        let configuration = context.configuration
        guard context.state.selectedMutant == nil, configuration.withPropertyTestFilter() != nil else { return }
        let kills = configuration.propertyTests.map { Self.propertyRerunCandidates(in: context.session, globs: $0) }
            ?? []
        let survivors = configuration.runsForEachSurvivor > 0
            ? Self.propertySurvivorCandidates(in: context.session, limit: configuration.survivorsToTestAgain)
            : (indices: [], leftOut: 0)
        guard !kills.isEmpty || !survivors.indices.isEmpty else { return }
        try Task.checkCancellation()
        let pool = workers.compactMap { worker in
            worker.configuration.withPropertyTestFilter().map {
                PoolWorker(directory: worker.directory, configuration: $0)
            }
        }
        guard let first = pool.first else { return }

        let baseline = try await Self.runControl(
            0,
            on: (0, first),
            at: (first.directory, testOutput(named: Self.propertyBaselineLogName, state: context.state)),
            from: testRun,
            using: runDependencies
        )
        try Self.throwIfCancelled(baseline.run)
        let log = fileManager.keepLog(
            baseline.run.testLog,
            writtenTo: baseline.output,
            by: ioDelegate,
            named: Self.propertyBaselineLogName,
            state: context.state
        )
        if let reason = Self.whyPropertyRerunsMeanNothing(baseline.run) {
            let logName = log.map { _ in Self.propertyBaselineLogName }
            if !kills.isEmpty {
                events.send(.propertyRerunsSkipped(reason: reason, log: logName))
            }
            if !survivors.indices.isEmpty {
                events.send(.propertySurvivorRerunsSkipped(reason: reason, log: logName))
            }
            return
        }

        try await rerunKillsWithPropertyTests(kills, of: jobs, on: pool, from: testRun, in: context)
        try await rerunSurvivorsWithPropertyTests(survivors, of: jobs, on: pool, from: testRun, in: context)
    }

    /// Tests each of `candidates`, kills whose recorded tests include no property test, again once with the property
    /// tests on `pool`, the workers' configurations already filtered to them.
    private func rerunKillsWithPropertyTests(
        _ candidates: [Int],
        of jobs: [MutantJob],
        on pool: [PoolWorker],
        from testRun: XCTestRun,
        in context: RunContext
    ) async throws {
        guard let first = pool.first, !candidates.isEmpty else { return }
        let reruns = PropertyReruns(count: candidates.count, workers: min(pool.count, candidates.count))
        events.send(.propertyRerunsStarted(reruns))
        var tally = PropertyRerunTally(reruns)
        try await runPool(
            PoolWork(tasks: candidates.map(PoolTask.mutant), jobs: jobs, testRun: testRun),
            on: Array(pool.prefix(reruns.workers)),
            outputNamed: { testOutput(named: logFileName(forPropertyRerunOfJobAt: $0, $1), state: context.state) },
            recording: { finished in
                try recordPropertyRerun(
                    finished, tally: &tally, in: context.with(first.configuration)
                )
            }
        )
        events.send(.propertyRerunsFinished(tally))
    }

    /// Why the property tests' run with no mutant on makes reruns with a mutant on mean nothing: it ran no test, as a
    /// filter that matches none doesn't, which `swift test` passes and a test bundle run directly fails, so every
    /// rerun would mean nothing; or it didn't pass, so a failure with a mutant on says nothing of the mutant. nil when
    /// it passed having run some.
    static func whyPropertyRerunsMeanNothing(_ run: TestRun) -> String? {
        guard testsRun(in: run.testLog) > 0 else {
            return "with no mutant on, the tests propertyTestFilter selects ran none, so it may match no test"
        }
        guard run.outcome == .passed else {
            return "the tests propertyTestFilter selects didn't pass with no mutant on"
        }
        return nil
    }

    /// How many tests `log` shows running: each Swift Testing run's `Test run with 12 tests …` line, and the most any
    /// of XCTest's `Executed 3 tests, with …` lines gives, as its suites' lines add up to its last.
    static func testsRun(in log: String) -> Int {
        let swiftTesting = counts(of: "Test run with ([0-9]+) tests? ", in: log).reduce(0, +)
        let xctest = counts(of: "Executed ([0-9]+) tests?, with", in: log).max() ?? 0
        return swiftTesting + xctest
    }

    /// The number `pattern`'s first group captures in each of its matches in `log`.
    private static func counts(of pattern: String, in log: String) -> [Int] {
        let regex = NSRegularExpression.regexWithPattern(pattern)
        return regex.matches(in: log, range: NSRange(log.startIndex..., in: log)).compactMap { match in
            Range(match.range(at: 1), in: log).flatMap { Int(log[$0]) }
        }
    }

    /// Writes `finished`, a kill's property rerun, to the results file after its mutant's line, keeps it in the
    /// mutant's outcome in `session`, and counts it in `tally`. Its log is kept unless a property test its line names
    /// failed, or every one passed, which its line says, or with `keepAllLogs`.
    func recordPropertyRerun(
        _ finished: FinishedRun,
        tally: inout PropertyRerunTally,
        in context: RunContext
    ) throws {
        let failures = MutantResult.failedTests(of: finished.run, ignoring: context.configuration.failedTestLookalikes)
        let key = context.session.keys[finished.index]
        let name = MutationTestLog.propertyRerunFileName(for: key)
        try abortingIfTheSimulatorIsGone(
            in: finished,
            logName: name,
            configuration: context.configuration,
            state: context.state
        )
        let keeps = finished.run.outcome == .passed
            ? context.configuration.keepsAllLogs
            : MutationTestLog.isKept(
                outcome: finished.run.outcome, killedBy: failures?.tests, keepingAll: context.configuration.keepsAllLogs
            )
        let keptLog = keeps && !context.state.loggingDirectory.isEmpty ? name : nil
        let record = PropertyRerunResult(
            key: key,
            finished: finished,
            failures: failures,
            session: context.session.number,
            finishedAt: now(),
            log: keptLog
        )
        write(record, in: context.session)
        context.session.outcomes[finished.index]?.propertyRerun = record.rerun
        fileManager.keepLog(
            finished.run.testLog, writtenTo: finished.output, by: ioDelegate, named: keptLog, state: context.state
        )
        tally.add(record.rerun)
    }

    /// The file a kill's property rerun writes its output to while it runs, which the mutant's own runs never share.
    func logFileName(forPropertyRerunOfJobAt index: Int, _ job: MutantJob) -> String {
        "\(index)_properties_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_\(job.schema.position).log"
    }
}
