import Foundation

/// What the example reruns came to, so far.
struct ExampleRerunTally: Equatable {
    let reruns: ExampleReruns
    private(set) var rerun = 0
    /// A test the `propertyTests` globs don't match failed: a kill by both kinds.
    private(set) var examplesFailed = 0
    /// Every test passed: a kill by properties alone.
    private(set) var passed = 0
    /// Timed out, failed to build, crashed, or only property tests the globs match failed: it settles nothing.
    private(set) var unsettled = 0

    init(_ reruns: ExampleReruns) {
        self.reruns = reruns
    }

    mutating func add(_ rerun: MutationTestOutcome.ExampleRerun, examplesFailed: Bool) {
        self.rerun += 1
        if examplesFailed {
            self.examplesFailed += 1
        } else if rerun.outcome == .passed {
            passed += 1
        } else {
            unsettled += 1
        }
    }
}

/// The kills a session tests again with every test but those `propertyTestFilter` selects, once every mutant is
/// tested: those whose recorded tests are all property tests, which `propertyTests` picks out, in a list cut short. A
/// run stopped at its first failed test records that test alone, so a property that failed first hides an example
/// that would also have failed. This run tells "only by properties" from "by both". It never changes a mutant's result.
/// SwiftPM only: no other test command stops at its first failed test.
struct ExampleReruns: Equatable {
    /// How many kills are tested again.
    let count: Int
    /// How many of them are tested at once.
    let workers: Int
}

extension PerformMutationTesting {
    static let exampleBaselineLogName = "tests but the property tests with no mutant on.log"

    /// The jobs, by index in job order, whose kill this session tests again with the property tests skipped: each a
    /// failed test killed, whose recorded tests are all ones `globs` match, in a list cut short, and with no example
    /// rerun yet. A list that holds every test that failed can't hide an example, and a crash is no failed test. As
    /// for `propertyRerunCandidates`: never a kill not in this session's build, or whose code didn't run.
    static func exampleRerunCandidates(in session: TestingSession, globs: [String]) -> [Int] {
        let patterns = globs.map(PropertyTestPattern.init)
        return session.outcomes.sorted { $0.key < $1.key }.compactMap { index, mutation in
            guard !session.notInTheBuild.contains(index), mutation.testSuiteOutcome == .failed,
                  mutation.exampleRerun == nil, mutation.activated != .didNotRun,
                  let killing = mutation.killingTests, !killing.isComplete, !killing.tests.isEmpty,
                  killing.tests.allSatisfy({ test in patterns.contains { $0.matches(.init(test)) } })
            else { return nil }
            return index
        }
    }

    /// Tests each of this session's kills by properties alone in a list cut short again, on `workers` at once, with
    /// every test but those `propertyTestFilter` selects, and fail-fast as the mutants' runs have it. Nothing without
    /// a filter, for `--mutant`'s one mutant, for a test command other than `swift test`, or with no such kill. First
    /// those tests run once with no mutant on: if they don't pass, or ran no test, no kill is tested again, as every
    /// rerun would mean nothing, and that is said. Each rerun's line follows its mutant's, which it never replaces.
    func rerunKillsWithExamples(
        of jobs: [MutantJob],
        on workers: [PoolWorker],
        from testRun: XCTestRun,
        in context: RunContext
    ) async throws {
        guard context.state.selectedMutant == nil, let globs = context.configuration.propertyTests,
              context.configuration.withPropertyTestsSkipped() != nil
        else { return }
        let candidates = Self.exampleRerunCandidates(in: context.session, globs: globs)
        guard !candidates.isEmpty else { return }
        try Task.checkCancellation()
        let pool = workers.compactMap { worker in
            worker.configuration.withPropertyTestsSkipped().map {
                PoolWorker(directory: worker.directory, configuration: $0)
            }
        }
        guard let first = pool.first else { return }

        let baseline = try await Self.runControl(
            0,
            on: (0, first),
            at: (first.directory, testOutput(named: Self.exampleBaselineLogName, state: context.state)),
            from: testRun,
            using: runDependencies
        )
        try Self.throwIfCancelled(baseline.run)
        let log = fileManager.keepLog(
            baseline.run.testLog,
            writtenTo: baseline.output,
            by: ioDelegate,
            named: Self.exampleBaselineLogName,
            state: context.state
        )
        if let reason = Self.whyExampleRerunsMeanNothing(baseline.run) {
            events.send(.exampleRerunsSkipped(reason: reason, log: log.map { _ in Self.exampleBaselineLogName }))
            return
        }

        let reruns = ExampleReruns(count: candidates.count, workers: min(pool.count, candidates.count))
        events.send(.exampleRerunsStarted(reruns))
        var tally = ExampleRerunTally(reruns)
        let patterns = globs.map(PropertyTestPattern.init)
        let isProperty = { (test: FailedTestLine.TestIdentity) in patterns.contains { $0.matches(test) } }
        try await runPool(
            PoolWork(tasks: candidates.map(PoolTask.mutant), jobs: jobs, testRun: testRun),
            on: Array(pool.prefix(reruns.workers)),
            outputNamed: { testOutput(named: logFileName(forExampleRerunOfJobAt: $0, $1), state: context.state) },
            recording: { finished in
                let rerun = try recordExampleRerun(finished, in: context.with(first.configuration))
                tally.add(rerun, examplesFailed: rerun.examplesFailed(isProperty: isProperty))
            }
        )
        events.send(.exampleRerunsFinished(tally))
    }

    /// Why the run with no mutant on of every test but the property tests makes reruns with a mutant on mean nothing:
    /// it ran no test, so every rerun would pass and mean nothing; or it didn't pass, so a failure with a mutant on
    /// says nothing of the mutant. nil when it passed having run some.
    static func whyExampleRerunsMeanNothing(_ run: TestRun) -> String? {
        guard testsRun(in: run.testLog) > 0 else {
            return "with no mutant on and the tests propertyTestFilter selects skipped, no test ran"
        }
        guard run.outcome == .passed else {
            return "with no mutant on, the tests left once propertyTestFilter's are skipped didn't pass"
        }
        return nil
    }

    /// Writes `finished`, a kill's example rerun, to the results file after its mutant's line, keeps it in the mutant's
    /// outcome in `session`, and gives it. Its log is kept unless a test its line names failed, or every one passed,
    /// which its line says, or with `keepAllLogs`.
    func recordExampleRerun(
        _ finished: FinishedRun,
        in context: RunContext
    ) throws -> MutationTestOutcome.ExampleRerun {
        let failures = MutantResult.failedTests(of: finished.run, ignoring: context.configuration.failedTestLookalikes)
        let key = context.session.keys[finished.index]
        let name = MutationTestLog.exampleRerunFileName(for: key)
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
        let record = ExampleRerunResult(
            key: key,
            finished: finished,
            failures: failures,
            session: context.session.number,
            finishedAt: now(),
            log: keptLog
        )
        write(record, in: context.session)
        context.session.outcomes[finished.index]?.exampleRerun = record.rerun
        fileManager.keepLog(
            finished.run.testLog, writtenTo: finished.output, by: ioDelegate, named: keptLog, state: context.state
        )
        return record.rerun
    }

    /// The file a kill's example rerun writes its output to while it runs, which no other run shares.
    func logFileName(forExampleRerunOfJobAt index: Int, _ job: MutantJob) -> String {
        "\(index)_examples_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_\(job.schema.position).log"
    }
}
