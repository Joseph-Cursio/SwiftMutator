import Foundation
import SwiftSyntax

/// The mutants' runs, one at a time or on several workers at once, and the files their output is written to.
extension PerformMutationTesting {
    /// Tests `plan`'s mutants of `jobs` with `setup`'s configuration, `context`'s, on its workers, one at a time or at
    /// once, with the control runs among them, once the first estimate of the time left, from the passing `baseline`,
    /// is sent.
    func runMutants(
        of jobs: [MutantJob],
        testing plan: ResumePlan,
        after baseline: BaselineRun,
        setup: MutantRunSetup,
        in context: RunContext
    ) async throws {
        // The first estimate of the time left: every mutant to test, spread over the workers.
        events.send(
            .newTestLogAvailable(MutationTestLog(
                mutationPoint: .none,
                testLog: baseline.testLog,
                timePerBuildTestCycle: baseline.seconds,
                remainingMutationPointsCount: plan.toRun.count,
                workers: setup.workers,
                testRunSeconds: setup.testRunSeconds
            ))
        )

        let tasks = Self.tasks(plan.toRun, controlRunEvery: Self.controlRunEvery(context.state, context.configuration))
        if setup.workers > 1 {
            try await testMutationsInParallel(jobs, tasks, workers: setup.workers, in: context)
        } else {
            try await testMutations(jobs, tasks, in: context)
        }
    }

    /// Runs `tasks`, in their order, one at a time in the mutated project: the jobs' mutants, and the control runs
    /// among them.
    func testMutations(
        _ jobs: [MutantJob],
        _ tasks: [PoolTask],
        in context: RunContext
    ) async throws {
        var buildErrors = 0
        let controlRuns = (Self.controlRunCount(in: tasks), Self.controlRunEvery(context.state, context.configuration))
        events.send(.mutantRunsStarted)
        heartbeat.begin(workers: 1, at: instant())
        let beating = beat()
        defer { beating.cancel() }
        let worker = PoolWorker(
            directory: context.state.mutatedProjectDirectoryURL,
            configuration: context.configuration
        )

        for task in tasks {
            try Task.checkCancellation()
            switch task {
            case let .mutant(index):
                let finished = try await runMutantInTheProject(jobs[index], at: index, in: context)
                try record(
                    finished,
                    of: jobs[index],
                    in: context,
                    buildErrors: &buildErrors
                )

            case let .control(number):
                let finished = try await Self.runControl(
                    number,
                    on: (0, worker),
                    at: (nil, testOutput(named: Self.place(ofControlRun: number), state: context.state)),
                    from: context.state.projectXCTestRun,
                    using: runDependencies
                )
                try Self.throwIfCancelled(finished.run)
                try recordControlRun(
                    finished,
                    number: number,
                    of: controlRuns,
                    in: context
                )
            }
        }
        // One worker has tested no timeout again, so they all count here.
        try await rerunKills(of: jobs, on: [worker], includingTimeouts: true, in: context)
    }

    /// Runs `job`'s mutant, the job at `index`, in the mutated project, the current directory, with `context`'s
    /// configuration, once it is switched on (`switchOn`). A run that returns once mutation testing is cancelled
    /// throws.
    private func runMutantInTheProject(
        _ job: MutantJob,
        at index: Int,
        in context: RunContext
    ) async throws -> FinishedRun {
        try await Self.switchOn(
            job,
            from: context.state.projectXCTestRun,
            in: context.state.mutatedProjectDirectoryURL,
            for: context.configuration,
            using: ioDelegate
        )

        let output = testOutput(named: logFileName(forJobAt: index, job), state: context.state)
        let finished = await FinishedRun.make(
            index: index,
            worker: 0,
            configuration: context.configuration,
            instant: instant,
            heartbeat: (heartbeat, place: Self.place(of: job))
        ) {
            await ioDelegate.runTestSuite(
                withSchemata: job.schema,
                using: context.configuration,
                savingResultsIntoFileNamed: output
            )
        }
        .writing(to: output)
        try Self.throwIfCancelled(finished.run)
        return finished
    }

    /// Once the mutants' runs are over, tests again, on `pool`'s first worker, the kills not shown to run their code,
    /// and the timeouts too `includingTimeouts`, then the kills only suspect tests failed for, and then, on all of
    /// `pool`, the kills by examples alone with the property tests.
    private func rerunKills(
        of jobs: [MutantJob],
        on pool: [PoolWorker],
        includingTimeouts: Bool,
        in context: RunContext
    ) async throws {
        try await rerunRunsNotShownToReachTheirCode(
            of: jobs,
            on: pool[0],
            includingTimeouts: includingTimeouts,
            in: context
        )
        try await rerunSuspectKills(
            of: jobs,
            on: pool[0],
            from: context.state.projectXCTestRun,
            in: context
        )
        try await rerunPropertyTests(
            of: jobs,
            on: pool,
            from: context.state.projectXCTestRun,
            in: context
        )
    }

    /// Sends the mutants under way whenever `heartbeat` says none has finished for a while, until cancelled. It reads
    /// the clock only once a wait ends, the first a whole interval, so it never moves a test's scripted clock on.
    private func beat() -> Task<Void, Never> {
        // Given the values and the dependencies it uses, not the step. Its sleep ends once it is cancelled.
        Task { [heartbeat, events, sleep, instant] in
            var wait = Heartbeat.interval
            while (try? await sleep(Suspensions.nanoseconds(wait))) != nil {
                let time = instant()
                if let still = heartbeat.due(at: time) {
                    events.send(.stillTesting(still))
                }
                wait = heartbeat.secondsUntilDue(at: time)
            }
        }
    }

    /// Runs `tasks`, started in their order, on `workers` test processes at once, never more than `tasks`: the jobs'
    /// mutants, and the control runs among them. A SwiftPM worker runs in its own clone of the mutated project:
    /// `swift test` locks the package's build directory, so two runs can't share one. An xcodebuild worker runs in the
    /// mutated project, on its own simulator, from its own `.xctestrun`, as `session.xcodeWorkers` has it; it needs
    /// no clone, as nothing is built again. Every mutant is switched on per run: under `swift test` by the worker's
    /// active-mutant file, written just before the run (see `MutationTestingDelegate.testProcess`), so the clones' code
    /// never needs rewriting, and under xcodebuild in the worker's `.xctestrun` (`runPool`). Outcomes are recorded,
    /// and their events sent, as they finish. The timeouts are then tested again, on fewer workers (`rerunTimeouts`).
    /// The clones are in `session`, made and built by `workers(testing:on:after:state:session:)`, and
    /// `run(with:)` removes them once the end line is written. Once mutation testing is cancelled, no mutant starts,
    /// and none that returns is recorded.
    func testMutationsInParallel(
        _ jobs: [MutantJob],
        _ tasks: [PoolTask],
        workers: Int,
        in context: RunContext
    ) async throws {
        try Task.checkCancellation()
        let pool = Self.pool(of: workers, in: context)

        var buildErrors = 0
        var timeouts: [Int] = []
        let controlRuns = (Self.controlRunCount(in: tasks), Self.controlRunEvery(context.state, context.configuration))
        events.send(.mutantRunsStarted)
        heartbeat.begin(workers: pool.count, at: instant())
        let beating = beat()
        defer { beating.cancel() }

        try await runPool(
            PoolWork(tasks: tasks, jobs: jobs, testRun: context.state.projectXCTestRun),
            on: pool,
            outputNamed: { testOutput(named: logFileName(forJobAt: $0, $1), state: context.state) },
            controlOutputNamed: { testOutput(named: Self.place(ofControlRun: $0), state: context.state) },
            recordingControlRun: { number, finished in
                try recordControlRun(
                    finished,
                    number: number,
                    of: controlRuns,
                    in: context
                )
            },
            recording: { finished in
                try record(
                    finished,
                    of: jobs[finished.index],
                    in: context,
                    buildErrors: &buildErrors
                )
                // A run the limit stopped whose log shows a failure is a kill, which another run wouldn't change.
                if finished.run.outcome == .timeout {
                    timeouts.append(finished.index)
                }
            }
        )
        try await rerunTimeouts(timeouts.sorted(), of: jobs, on: pool, in: context)
        try await rerunKills(of: jobs, on: pool, includingTimeouts: false, in: context)
    }

    /// The `workers` that test at once: an xcodebuild run's in the mutated project, each from its own `.xctestrun` and
    /// on its own simulator, as `context.session.xcodeWorkers` has them; a SwiftPM run's in the mutated project and
    /// each of its clones.
    private static func pool(of workers: Int, in context: RunContext) -> [PoolWorker] {
        if context.configuration.buildSystem == .xcodebuild {
            return context.session.xcodeWorkers.prefix(workers).map {
                PoolWorker(
                    directory: context.state.mutatedProjectDirectoryURL,
                    configuration: context.configuration.forXcodeWorker($0)
                )
            }
        }
        return ([context.state.mutatedProjectDirectoryURL] + context.session.clones).map {
            PoolWorker(directory: $0, configuration: context.configuration)
        }
    }

    /// Tests the jobs at `indices` again, whose runs timed out, in job order, on the first quarter of `workers` at
    /// once, at least one, never more than `indices`: with every worker's tests competing for the same cores, a slow
    /// test can pass the limit that it keeps to under less load. The limit is `configuration`'s, the first runs', which
    /// every worker's shares, so a mutant that loops forever times out again. Each run's line follows its first run's,
    /// which it replaces, and its events don't count in the progress, which counted the first run (`recordRerun`).
    private func rerunTimeouts(
        _ indices: [Int],
        of jobs: [MutantJob],
        on workers: [PoolWorker],
        in context: RunContext
    ) async throws {
        guard !indices.isEmpty else { return }
        try Task.checkCancellation()
        let reruns = TimeoutReruns(
            count: indices.count,
            workers: min(max(workers.count / 4, 1), indices.count),
            limitSeconds: context.configuration.testSuiteTimeout
        )
        events.send(.timeoutRerunsStarted(reruns))
        var tally = TimeoutRerunTally(reruns)
        try await runPool(
            PoolWork(tasks: indices.map(PoolTask.mutant), jobs: jobs, testRun: context.state.projectXCTestRun),
            on: Array(workers.prefix(reruns.workers)),
            outputNamed: { testOutput(named: logFileName(forRerunOfJobAt: $0, $1), state: context.state) },
            recording: { finished in
                try recordRerun(
                    finished,
                    of: jobs[finished.index],
                    tally: &tally,
                    in: context
                )
            }
        )
        events.send(.timeoutRerunsFinished(tally))
    }

    /// The file a mutant's run writes its output to while it runs. Its job's number comes first, so two runs under way
    /// at once never share one, as mutants in same-named files at the same place, or a repeated mutant, otherwise
    /// would: the first to finish would remove the file the other still has to read.
    private func logFileName(forJobAt index: Int, _ job: MutantJob) -> String {
        "\(index)_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_\(job.schema.position).log"
    }

    /// The file the run that tests a mutant again writes its output to while it runs, which the first run's output, if
    /// a stop left it, never shares.
    func logFileName(forRerunOfJobAt index: Int, _ job: MutantJob) -> String {
        "\(index)_rerun_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_\(job.schema.position).log"
    }

    /// Where the test run whose log is `name` writes its output while it runs: `testOutputFolderName` in the run's
    /// log folder, or, without one, as a state that bypasses the handler has, the current directory.
    func testOutput(named name: String, state: AnyMutationTestState) -> String {
        guard !state.loggingDirectory.isEmpty else { return name }
        return state.loggingDirectory
            .appendingPathComponent(Self.testOutputFolderName)
            .appending("/\(name)")
    }

    /// Removes the run's test-output folder if it is empty, as it is once every recorded run's output is kept or
    /// discarded, so a finished run's log folder holds only the logs it keeps. A stop or an abort leaves the folder,
    /// with the output of the runs under way, or finished but not recorded.
    func removeTestOutputFolderIfEmpty(_ state: AnyMutationTestState) {
        guard !state.loggingDirectory.isEmpty else { return }
        let folder = state.loggingDirectory.appendingPathComponent(Self.testOutputFolderName)
        removeFolderIfEmpty(atPath: folder, fileManager: fileManager)
    }
}
