import Foundation

/// What the step's extensions in other files use too, such as ControlRuns.swift.
extension PerformMutationTesting {
    /// "Rules.swift:42:17": where `job`'s mutant is, as the progress lines give it.
    static func place(of job: MutantJob) -> String {
        "\(job.fileName):\(job.schema.position.line):\(job.schema.position.column)"
    }

    /// A run that returns once mutation testing is cancelled may have been ended by SwiftMutator itself, whatever
    /// it says: a process killed before its run's cancellation handler was installed reads as an exit with status
    /// 9, which counts as killed. Such a run is never recorded.
    static func throwIfCancelled(_ run: TestRun) throws {
        if run.ending == .cancelled || Task.isCancelled { throw CancellationError() }
    }

    /// Whether `written`, what `TestingSession.append` returned, says the line was written. A failure is said once.
    @discardableResult
    func sayingAFailure(_ written: Bool?, in session: TestingSession) -> Bool {
        guard let written else { return false }
        if !written, !session.saidResultsUnwritable, let results = session.results {
            session.saidResultsUnwritable = true
            let reason = results.writeError.map { "\($0)" } ?? "a write to \(results.path) failed"
            events.send(.resultsFileUnavailable(reason: reason))
        }
        return written
    }

    /// Appends `line` to the session's results file, if it has one, and counts it in the session's `recorded` if it
    /// `isAMutant`. After a failed write, or once the session has ended, no line is written, or even built, and the
    /// failure is said once.
    @discardableResult
    func write<Line: Encodable>(
        _ line: @autoclosure () -> Line,
        in session: TestingSession,
        isAMutant: Bool = false
    ) -> Bool {
        sayingAFailure(session.append(line, isAMutant: isAMutant), in: session)
    }

    /// Aborts mutation testing, with `finished`'s log kept beside `logName`, the name its result would have, if the
    /// simulator it ran on is gone: every run on it would fail, and none tested its mutant. Called before the result is
    /// written, so that run is never recorded.
    func abortingIfTheSimulatorIsGone(
        in finished: FinishedRun,
        logName: String,
        configuration: MuterConfiguration,
        state: AnyMutationTestState
    ) throws {
        guard case let .deviceGone(line) = SimulatorTrouble.of(finished.run, with: configuration) else { return }
        let log = fileManager.keepLog(
            finished.run.testLog,
            writtenTo: finished.output,
            by: ioDelegate,
            named: MutationTestLog.simulatorGoneFileName(for: logName),
            state: state
        )
        throw MuterError.mutationTestingAborted(
            reason: .simulatorUnavailable(worker: finished.worker, line: line, log: log)
        )
    }
}

/// The jobs, one per mutant, and the workers that test them at once.
extension PerformMutationTesting {
    struct MutantJob {
        let fileName: FileName
        let schema: MutationSchema
    }

    /// A worker that tests mutants at once with the others: the folder its runs start in, and the configuration they
    /// run with. A SwiftPM worker's folder is its own, the mutated project or a clone of it, or, when workers share a
    /// build (`DirectTestRun.sharedBuild`), the name of a clone that was never made, and every worker shares one
    /// configuration. An xcodebuild worker's configuration names what is its own instead
    /// (`MuterConfiguration.XcodeWorker`), whatever folder it runs in.
    struct PoolWorker {
        let directory: URL
        let configuration: MuterConfiguration
    }

    /// What a pool runs: its tasks, in the order they start, the jobs a mutant's task is the index of, and the
    /// `.xctestrun` an xcodebuild worker switches each mutant on from.
    struct PoolWork {
        let tasks: [PoolTask]
        let jobs: [MutantJob]
        let testRun: XCTestRun
    }

    /// What a test run's task is given in place of the step: the delegate that runs the tests, the monotonic clock
    /// that times them, and the heartbeat that names the runs under way.
    struct RunDependencies {
        let ioDelegate: MutationTestingIODelegate
        let instant: Instant
        let heartbeat: Heartbeat
    }

    /// The step's dependencies a test run's task uses.
    var runDependencies: RunDependencies {
        RunDependencies(ioDelegate: ioDelegate, instant: instant, heartbeat: heartbeat)
    }

    /// The seconds from `start` to `end`, two readings of the monotonic clock; none if `end` is the earlier.
    static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        guard end >= start else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Runs `work.tasks`, started in their order, one at a time on each of `workers`, and hands each mutant's run to
    /// `record`, and each control run to `recordControlRun`, as it finishes; the worker that finished it then starts
    /// the next task. A control run writes its output to the file `controlOutputName` names (`runControl`), which only
    /// tasks with no control run may leave out. An xcodebuild worker first switches its job's mutant on in its own
    /// `.xctestrun`, written from `work.testRun`, as the serial path does; a SwiftPM run writes its worker's
    /// active-mutant file itself (see `MutationTestingDelegate.testProcess`). A worker runs one job at a time, so
    /// nothing rewrites either file during a run. Each run writes its output to the file `outputName` names for its job
    /// while it runs. Once mutation testing is cancelled, no job starts, and no run that returns is handed on.
    func runPool(
        _ work: PoolWork,
        on workers: [PoolWorker],
        outputNamed outputName: (_ index: Int, _ job: MutantJob) -> String,
        controlOutputNamed controlOutputName: (_ number: Int) -> String? = { _ in nil },
        recordingControlRun recordControlRun: (_ number: Int, FinishedRun) throws -> Void = { _, _ in },
        recording record: (FinishedRun) throws -> Void
    ) async throws {
        let tasks = work.tasks
        try await withThrowingTaskGroup(of: (task: PoolTask, finished: FinishedRun).self) { group in
            // The position in `tasks` of the next task to start.
            var next = 0
            // Throws once mutation testing is cancelled, rather than skip the task: with no run under way, the
            // loop below would end as if every mutant had been tested.
            func start(_ task: PoolTask, worker: Int) throws {
                let run = run(
                    task,
                    on: (worker, workers[worker]),
                    of: work,
                    outputNamed: outputName,
                    controlOutputNamed: controlOutputName
                )
                guard group.addTaskUnlessCancelled(operation: { (task, try await run()) }) else {
                    throw CancellationError()
                }
            }

            for worker in workers.indices.prefix(tasks.count) {
                try start(tasks[next], worker: worker)
                next += 1
            }

            // A mutant that couldn't be switched on throws here too, and stops mutation testing.
            while let (task, finished) = try await group.next() {
                // Throwing cancels the other runs, whose cancellation handlers kill their process trees.
                try Self.throwIfCancelled(finished.run)
                if case let .control(number) = task {
                    try recordControlRun(number, finished)
                } else {
                    try record(finished)
                }
                // The worker that finished takes the next task.
                if next < tasks.count {
                    try start(tasks[next], worker: finished.worker)
                    next += 1
                }
            }
        }
    }

    /// The run of `task` on `worker.1`, numbered `worker.number`, ready to start: a control run, writing its output to
    /// the file `controlOutputName` names, or "" for none (`runControl`), or the mutant's run of a job of `work`,
    /// writing its output to the file `outputName` names for it (`runMutant`). It is given the values and the
    /// dependencies it uses, not the step.
    private func run(
        _ task: PoolTask,
        on worker: (number: Int, PoolWorker),
        of work: PoolWork,
        outputNamed outputName: (_ index: Int, _ job: MutantJob) -> String,
        controlOutputNamed controlOutputName: (_ number: Int) -> String?
    ) -> @Sendable () async throws -> FinishedRun {
        let (testRun, dependencies) = (work.testRun, runDependencies)
        switch task {
        case let .control(number):
            // A run named "" has no output to keep or discard (`FinishedRun.writing(to:)`).
            let fileName = controlOutputName(number) ?? ""
            return {
                try await Self.runControl(
                    number, on: worker, at: (worker.1.directory, fileName), from: testRun, using: dependencies
                )
            }

        case let .mutant(index):
            let job = work.jobs[index]
            let fileName = outputName(index, job)
            return {
                try await Self.runMutant(
                    (index, job), on: worker, from: testRun, fileName: fileName, using: dependencies
                )
            }
        }
    }

    /// Runs the mutant of `indexedJob`, the job at its index, on `worker.1`, numbered `worker.number`, with its
    /// configuration, in its folder, writing its output to `fileName` while it runs. An xcodebuild worker first
    /// switches the mutant on in its own `.xctestrun`, written from `testRun` (`switchOn`).
    static func runMutant(
        _ indexedJob: (index: Int, MutantJob),
        on worker: (number: Int, PoolWorker),
        from testRun: XCTestRun,
        fileName: String,
        using dependencies: RunDependencies
    ) async throws -> FinishedRun {
        let (index, job) = indexedJob
        let (directory, configuration) = (worker.1.directory, worker.1.configuration)
        let ioDelegate = dependencies.ioDelegate
        if configuration.buildSystem == .xcodebuild {
            try await switchOn(job, from: testRun, in: directory, for: configuration, using: ioDelegate)
        }
        return await FinishedRun.make(
            index: index,
            worker: worker.number,
            configuration: configuration,
            instant: dependencies.instant,
            heartbeat: (dependencies.heartbeat, place: place(of: job))
        ) {
            await ioDelegate.runTestSuite(
                withSchemata: job.schema,
                using: configuration,
                savingResultsIntoFileNamed: fileName,
                workingDirectory: directory
            )
        }
        .writing(to: fileName)
    }

    /// Switches `job`'s mutant on for a run with `configuration` in `directory`, by writing `testRun` with it on to
    /// the `.xctestrun` that run tests from: its xcodebuild worker's, or `muter.xctestrun`. A file that couldn't be
    /// written would still switch on the mutant before this one, whose verdict an xcodebuild run would record for this
    /// one, so that aborts mutation testing.
    static func switchOn(
        _ job: MutantJob,
        from testRun: XCTestRun,
        in directory: URL,
        for configuration: MuterConfiguration,
        using ioDelegate: MutationTestingIODelegate
    ) async throws {
        do {
            try await ioDelegate.switchOn(
                schemata: job.schema,
                for: testRun,
                at: directory,
                named: configuration.xcodeWorker?.testRunFile ?? MutationTestingDelegate.muterTestRunFileName
            )
        } catch {
            throw MuterError.mutationTestingAborted(
                reason: .mutantNotSwitchedOn(id: job.schema.id, description: error.localizedDescription)
            )
        }
    }
}
