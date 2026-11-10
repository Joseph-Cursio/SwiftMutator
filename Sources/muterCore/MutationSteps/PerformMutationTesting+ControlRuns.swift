import Foundation

/// A control run, once its line is written, and how many the session runs.
struct ControlRunFinished: Equatable {
    let record: ControlRunResult
    let count: Int
}

/// Control runs: the test command with no mutant on, run every so often among the mutants, on a worker of theirs and
/// under the same time limit and load. A passing baseline shows the tests pass alone; a control run shows whether they
/// pass beside the other workers' runs. A test that fails in one is flaky, and the reports count a kill that only such
/// tests were recorded failing for as suspect (`KillingTestSummary`).
extension PerformMutationTesting {
    /// What a worker runs next: the job at an index of the session's jobs, or the control run of a number, from 1.
    enum PoolTask: Equatable {
        case mutant(Int)
        case control(Int)
    }

    /// The jobs at `indices`, in their order, with one control run for each whole `every` of them, none if `every` is
    /// 0. Control run k starts once `mutantsBefore(controlRun: k, every:)` mutants have: halfway through its stretch,
    /// so none runs as the workers start, or as they drain.
    static func tasks(_ indices: [Int], controlRunEvery every: Int) -> [PoolTask] {
        guard every > 0 else { return indices.map(PoolTask.mutant) }
        let controlRuns = indices.count / every
        var tasks: [PoolTask] = []
        tasks.reserveCapacity(indices.count + controlRuns)
        var next = 1
        for (position, index) in indices.enumerated() {
            if next <= controlRuns, position == mutantsBefore(controlRun: next, every: every) {
                tasks.append(.control(next))
                next += 1
            }
            tasks.append(.mutant(index))
        }
        return tasks
    }

    /// How many mutants start before control run `number`, of one for each `every`.
    static func mutantsBefore(controlRun number: Int, every: Int) -> Int {
        (number - 1) * every + every / 2
    }

    /// How many mutants a control run is run for: the configuration's, but none for the one mutant `--mutant` tests,
    /// which is no stretch of a run to check.
    static func controlRunEvery(_ state: AnyMutationTestState, _ configuration: MuterConfiguration) -> Int {
        state.selectedMutant == nil ? configuration.mutantsPerControlRun : 0
    }

    /// How many control runs `tasks` holds.
    static func controlRunCount(in tasks: [PoolTask]) -> Int {
        tasks.count { if case .control = $0 { true } else { false } }
    }

    /// "control run 2": where control run `number` is, as the progress lines name what is under way.
    static func place(ofControlRun number: Int) -> String {
        "control run \(number)"
    }

    /// Runs control run `number` on worker `worker.number`, with its configuration, in `location.directory`, its
    /// folder, or the current directory if nil, writing its output to `location.fileName` while it runs. An xcodebuild
    /// worker first writes `testRun` with no mutant on to its own `.xctestrun`, in its folder: one that couldn't be
    /// written would still switch on the mutant before, so that aborts mutation testing.
    static func runControl(
        _ number: Int,
        on worker: (number: Int, PoolWorker),
        at location: (directory: URL?, fileName: String),
        from testRun: XCTestRun,
        using dependencies: RunDependencies
    ) async throws -> FinishedRun {
        let ioDelegate = dependencies.ioDelegate
        let (workingDirectory, fileName) = location
        let (directory, configuration) = (worker.1.directory, worker.1.configuration)
        if configuration.buildSystem == .xcodebuild {
            do {
                try await ioDelegate.switchOn(
                    schemata: .null,
                    for: testRun,
                    at: directory,
                    named: configuration.xcodeWorker?.testRunFile ?? MutationTestingDelegate.muterTestRunFileName
                )
            } catch {
                throw MuterError.mutationTestingAborted(
                    reason: .controlRunNotSwitchedOff(number: number, description: error.localizedDescription)
                )
            }
        }
        return await FinishedRun.make(
            index: number,
            worker: worker.number,
            configuration: configuration,
            timing: FinishedRun.Timing(instant: dependencies.instant, heartbeat: dependencies.heartbeat, place: place(ofControlRun: number))
        ) {
            await ioDelegate.runControlTests(
                using: configuration,
                savingResultsIntoFileNamed: fileName,
                workingDirectory: workingDirectory
            )
        }
        .writing(to: fileName)
    }

    /// Writes `finished`, control run `number` of `runs.count`, of one for each `runs.every` mutants, to the results
    /// file, keeps it in `session` and its log in the log folder, and sends it. Its failed tests leave out the tests
    /// the baseline's lines showed failing, as a mutant's do. A run on a simulator that is gone is never recorded, and
    /// aborts mutation testing (`abortingIfTheSimulatorIsGone`). Never a mutant's outcome or log, which would count in
    /// the progress.
    func recordControlRun(
        _ finished: FinishedRun,
        number: Int,
        of runs: (count: Int, every: Int),
        in context: RunContext
    ) throws {
        let (count, every) = runs
        let log = ControlRunResult.logName(of: number)
        try abortingIfTheSimulatorIsGone(
            in: finished,
            logName: log,
            configuration: context.configuration,
            state: context.state
        )
        let record = ControlRunResult(
            number: number,
            afterMutants: Self.mutantsBefore(controlRun: number, every: every),
            finished: finished,
            failures: MutantResult.failedTests(of: finished.run, ignoring: context.configuration.failedTestLookalikes),
            session: context.session.number,
            finishedAt: now(),
            log: log
        )
        write(record, in: context.session)
        context.session.controlRuns.append(record)
        fileManager.keepLog(
            finished.run.testLog,
            writtenTo: finished.output,
            by: ioDelegate,
            named: log,
            state: context.state
        )
        if let failure = finished.launchFailure {
            fileManager.keepLog(
                failure.testLog,
                named: MutationTestLog.launchFailedFileName(for: log),
                state: context.state
            )
        }
        events.send(.controlRunFinished(ControlRunFinished(record: record, count: count)))
    }

    /// The control runs `outcome`s are reported with: those of the sessions a resumed run's results file holds, then
    /// this session's. Never a reused run's, whose file isn't this run's.
    static func controlRuns(
        of session: TestingSession,
        state: AnyMutationTestState
    ) -> [MutationTestOutcome.ControlRun] {
        let earlier = state.resumeState.map { $0.isReuse ? [] : $0.recorded.controlRuns } ?? []
        return (earlier + session.controlRuns).map(MutationTestOutcome.ControlRun.init)
    }
}
