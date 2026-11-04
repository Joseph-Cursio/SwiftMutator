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
    /// run with. A SwiftPM worker's folder is its own, the mutated project or a clone of it, and every worker shares
    /// one configuration. An xcodebuild worker's configuration names what is its own instead
    /// (`MuterConfiguration.XcodeWorker`), whatever folder it runs in.
    struct PoolWorker {
        let directory: URL
        let configuration: MuterConfiguration
    }

    /// The seconds from `start` to `end`, two readings of the monotonic clock; none if `end` is the earlier.
    static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        guard end >= start else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Runs `tasks`, started in their order, one at a time on each of `workers`, and hands each mutant's run to
    /// `record`, and each control run to `recordControlRun`, as it finishes; the worker that finished it then starts
    /// the next task. A control run writes its output to the file `controlOutputName` names (`runControl`), which only
    /// tasks with no control run may leave out. An xcodebuild worker first switches its job's mutant on in its own
    /// `.xctestrun`, written from `testRun`, as the serial path does; a SwiftPM run writes its worker's active-mutant
    /// file itself (see `MutationTestingDelegate.testProcess`). A worker runs one job at a time, so nothing rewrites
    /// either file during a run. Each run writes its output to the file `outputName` names for its job while it runs.
    /// Once mutation testing is cancelled, no job starts, and no run that returns is handed on.
    func runPool(
        _ tasks: [PoolTask],
        of jobs: [MutantJob],
        on workers: [PoolWorker],
        switchingOnFrom testRun: XCTestRun,
        outputNamed outputName: (_ index: Int, _ job: MutantJob) -> String,
        controlOutputNamed controlOutputName: (_ number: Int) -> String? = { _ in nil },
        recordingControlRun recordControlRun: (_ number: Int, FinishedRun) throws -> Void = { _, _ in },
        recording record: (FinishedRun) throws -> Void
    ) async throws {
        // The worker job loop and its inline cancellation handling genuinely span >30 lines; pulling the body
        // into a helper would split apart a tight loop-and-catch, so the length is disabled for this closure.
        // swiftlint:disable:next closure_body_length
        try await withThrowingTaskGroup(of: (task: PoolTask, finished: FinishedRun).self) { group in
            // The position in `tasks` of the next task to start.
            var next = 0
            // Throws once mutation testing is cancelled, rather than skip the task: with no run under way, the
            // loop below would end as if every mutant had been tested.
            func start(_ task: PoolTask, worker: Int) throws {
                let (directory, configuration) = (workers[worker].directory, workers[worker].configuration)
                guard case let .mutant(index) = task else {
                    guard case let .control(number) = task else { return }
                    // A run named "" has no output to keep or discard (`FinishedRun.writing(to:)`).
                    let fileName = controlOutputName(number) ?? ""
                    let poolWorker = workers[worker]
                    let started = group.addTaskUnlessCancelled { [ioDelegate, instant, heartbeat] in
                        let finished = try await Self.runControl(
                            number,
                            on: (worker, poolWorker),
                            workingDirectory: directory,
                            from: testRun,
                            fileName: fileName,
                            using: (ioDelegate, instant, heartbeat)
                        )
                        return (task, finished)
                    }
                    guard started else { throw CancellationError() }
                    return
                }
                let job = jobs[index]
                let fileName = outputName(index, job)
                // A worker's task is given the values and the two dependencies it uses, not the step.
                let started = group.addTaskUnlessCancelled { [ioDelegate, instant, heartbeat] in
                    if configuration.buildSystem == .xcodebuild {
                        try await Self.switchOn(
                            job, from: testRun, in: directory, for: configuration, using: ioDelegate
                        )
                    }
                    let finished = await FinishedRun.make(
                        index: index,
                        worker: worker,
                        configuration: configuration,
                        instant: instant,
                        heartbeat: (heartbeat, place: Self.place(of: job))
                    ) {
                        await ioDelegate.runTestSuite(
                            withSchemata: job.schema,
                            using: configuration,
                            savingResultsIntoFileNamed: fileName,
                            workingDirectory: directory
                        )
                    }.writing(to: fileName)
                    return (task, finished)
                }
                guard started else { throw CancellationError() }
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
