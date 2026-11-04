import Foundation
import SwiftSyntax

struct PerformMutationTesting: MutationStep {
    // These five aren't private, so the step's extensions in other files, such as ControlRuns.swift, can use them.
    @Dependency(\.ioDelegate)
    var ioDelegate: MutationTestingIODelegate
    @Dependency(\.events)
    var events: RunEvents
    @Dependency(\.fileManager)
    var fileManager: FileSystemManager
    @Dependency(\.now)
    var now: Now
    @Dependency(\.instant)
    var instant: Instant
    @Dependency(\.resultsFiles)
    private var resultsFiles: ResultsFileOpening
    @Dependency(\.provenance)
    private var provenance: ProvenanceProbe
    @Dependency(\.interruption)
    private var interruption: InterruptionRecord
    @Dependency(\.directTestRun)
    private var directTestRun: DirectTestRunProbe
    @Dependency(\.workerSimulators)
    private var workerSimulators: WorkerSimulating
    @Dependency(\.sleep)
    private var sleep: Sleep

    private let simulatorWorkerSetup = SimulatorWorkerSetup()
    private let timedTestRun = TimedTestRun()

    private let buildErrorsThreshold: Int = 5

    /// The folder in the run's log folder that each test run writes its output to while it runs. Never the mutated
    /// project or a clone, where a test that lists the package's files, or asks git for untracked ones, would see it.
    /// Each run's file goes once its log is read back (`MutationTestingDelegate`), and the log folder keeps its own
    /// copy, so only the output of runs a stop cut short stays.
    static let testOutputFolderName = "running"

    /// Clones the mutated project for each extra parallel worker, and removes the clones afterwards.
    /// Injected so tests don't touch the disk.
    private let makeWorkerDirectories: (_ mutatedProject: URL, _ count: Int) async throws -> [URL]
    private let removeWorkerDirectories: (_ directories: [URL]) -> Void
    /// The mutants under way, for the line that names them once none has finished for a while.
    let heartbeat = Heartbeat()

    init(
        makeWorkerDirectories: @escaping (URL, Int) async throws -> [URL] = PerformMutationTesting.cloneMutatedProject,
        removeWorkerDirectories: @escaping ([URL]) -> Void = PerformMutationTesting.removeClones
    ) {
        self.makeWorkerDirectories = makeWorkerDirectories
        self.removeWorkerDirectories = removeWorkerDirectories
    }

    /// Tests every mutant, writing each one's result to the run's results file as it finishes, between a header
    /// and an end line that says how mutation testing ended. Mutation testing that stops early then sends what it
    /// tested. Worker clones are removed last. A resumed run adds its session to the stopped run's results file, tests
    /// only the mutants without a recorded result that still holds, and reports the results it keeps with the ones it
    /// tests, in job order; its test duration adds the earlier sessions'. A run that reuses an earlier run's results
    /// does the same in a results file of its own, which starts with the results it keeps; its test duration is its
    /// own.
    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)
        let resume = state.resumeState
        let resumed = resume.flatMap { $0.isReuse ? nil : $0 }
        let session = TestingSession(
            number: (resumed?.lastSession ?? 0) + 1,
            startedAt: now(),
            earlierTestDuration: resumed?.recorded.testDuration ?? 0
        )
        // After the end line and anything sent about an early end: removing large clones can take seconds, and a
        // second signal in that time exits at once. A clone left behind is removed when SwiftMutator next runs.
        // The mutated project is kept, for a look after the run, but not the active-mutant file beside it, nor the
        // helper link and the tests' `UserDefaults` of direct runs, nor the derived data of xcodebuild's mutant runs,
        // which holds one run's at most, nor the `.xctestrun` files of xcodebuild workers beyond the first. They go
        // first: they take no time. Their simulators go once the work has ended (`SimulatorWorkerSetup`).
        defer {
            if state.muterConfiguration.buildSystem == .swift {
                let activeMutantFile = MutationTestingDelegate.activeMutantFile(
                    forWorkerIn: state.mutatedProjectDirectoryURL
                )
                try? fileManager.removeItem(atPath: activeMutantFile.path)
                DirectTestRun.removeOwnDefaults(forWorkerIn: state.mutatedProjectDirectoryURL)
            }
            if state.muterConfiguration.buildSystem == .xcodebuild {
                let derivedData = MuterConfiguration.XcodeWorker.derivedData(
                    ofWorker: 0,
                    in: state.mutatedProjectDirectoryURL
                )
                try? fileManager.removeItem(atPath: derivedData)
            }
            for worker in session.xcodeWorkers.dropFirst() {
                try? fileManager.removeItem(atPath: state.mutatedProjectDirectoryURL.path + "/" + worker.testRunFile)
                try? fileManager.removeItem(atPath: worker.derivedData)
            }
            removeTestOutputFolderIfEmpty(state)
            if !session.clones.isEmpty {
                removeWorkerDirectories(session.clones)
            }
        }
        // A resumed file's lock goes before the clones are removed, as a first session's goes at its end line: also
        // when the baseline failed, which writes nothing to the file.
        defer { resume?.file?.close() }
        // Stopping at once ends SwiftMutator wherever mutation testing is, so the end line is written then: `report`
        // would otherwise take the run for one that is still running, or was killed.
        interruption.beforeStoppingAtOnce { [interruption, now] in
            Self.endResultsAtOnce(of: session, stoppedBy: interruption, now: now)
        }
        defer { interruption.beforeStoppingAtOnce(nil) }

        do {
            try await performMutationTesting(using: state, session: session)
        } catch {
            let reason: ResultsEnd.Reason = error is CancellationError ? .interrupted : .aborted
            // The stopping signal tells a CI cancellation (SIGTERM) apart from a Ctrl-C (SIGINT). A cancellation
            // that no signal caused has no detail.
            let detail = reason == .interrupted
                ? interruption.signal.map(InterruptionRecord.name(of:))
                : ResultsEnd.detail(for: error)
            let thisSession = now().timeIntervalSince(session.startedAt)
            endResults(of: session, reason, detail: detail, testDuration: thisSession)
            sendEarlyEnd(
                of: session,
                reason,
                detail: detail,
                state: state,
                testDuration: session.earlierTestDuration + thisSession
            )
            throw error
        }

        let thisSession = now().timeIntervalSince(session.startedAt)
        endResults(of: session, .finished, testDuration: thisSession)

        let mutationTestOutcome = MutationTestOutcome(
            mutations: session.outcomesInJobOrder,
            coverage: state.projectCoverage.limited(
                to: state.changeSelection,
                inCopyAt: state.mutatedProjectDirectoryURL
            ),
            coverageSkipped: state.runOptions.skipCoverage,
            testDuration: session.earlierTestDuration + thisSession,
            newVersion: state.newVersion,
            since: state.changeSelection,
            shards: state.shardSelection?.scopeAlone,
            sample: state.sampleSelection,
            mutant: state.selectedMutant?.description,
            suspectTestThresholds: state.muterConfiguration.suspectTestThresholds,
            controlRuns: Self.controlRuns(of: session, state: state),
            projectPath: state.projectDirectoryURL.path,
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            sourceDigests: Self.sourceDigests(of: state),
            run: Self.runDetails(of: session, state: state)
        )

        events.send(.mutationTestingFinished(mutationTestOutcome))

        return [.mutationTestOutcomeGenerated(mutationTestOutcome)]
    }
}

private extension PerformMutationTesting {
    /// Keeps each mutant's outcome, tested or kept, and each worker clone it makes, in `session`.
    func performMutationTesting(
        using state: AnyMutationTestState,
        session: TestingSession
    ) async throws {
        // What there is to test doesn't depend on the baseline, so it's known before the baseline runs. Whether a stop
        // has anything to report is whether the baseline passed, which the session records once it has.
        let jobs = Self.jobs(of: state)
        session.keys = MutantKey.keys(for: jobs.map(\.schema), under: state.mutatedProjectDirectoryURL)
        let plan = Self.plan(of: jobs, keyedBy: session.keys, state: state)
        let reused = keptResults(plan, of: jobs, state: state)
        await sweepLeftoverSimulators(state)

        if let resume = state.resumeState {
            session.earlierBuildErrors = Set(
                plan.toRun.filter { resume.recorded.latest[session.keys[$0]]?.outcome == .buildError }
            )
            events.send(
                .resumePlanned(ResumeSummary(
                    resume,
                    plan,
                    waived: state.resumeWaived,
                    coverage: state.projectCoverage,
                    in: state.mutatedProjectDirectoryURL,
                    reusing: resume.isReuse ? state.reuseChanges : nil,
                    selecting: (state.changeSelection, state.runOptions.shard, state.runOptions.sample),
                    sampleIsPartial: state.sampleSelection?.isPartial == true
                ))
            )
            // With every result kept there is nothing to test, so no baseline and no clones: the session is a header,
            // the retired line of mutants no longer discovered or sampled, if any, and the end line `run(with:)`
            // writes. A reuse
            // after any change still runs the baseline, below: a changed test that now fails would otherwise go unseen.
            if plan.toRun.isEmpty, !resume.isReuse || state.reuseChanges?.values.allSatisfy(\.isEmpty) != false {
                session.baselinePassed = true
                await startResults(
                    await header(
                        of: session,
                        plan,
                        state: state,
                        configuration: state.muterConfiguration,
                        baselineSeconds: nil,
                        workers: 0
                    ),
                    retiring: plan.retired,
                    copying: reused,
                    in: session,
                    state: state
                )
                keepReused(reused, of: jobs, in: session, state: state)
                return
            }
        }

        events.send(.mutationTestingStarted)

        // Only an explicit `true` asked for it, so only that is worth saying, and before the baseline run,
        // which can take minutes. Not a configuration error: the same configuration may be used with
        // another test command.
        if state.muterConfiguration.stopAtFirstFailure == true,
           let reason = state.muterConfiguration.stopAtFirstFailureUnsupportedReason {
            events.send(.stopAtFirstFailureTurnedOff(reason: reason))
        }

        // An xcodebuild run's workers' simulators boot while the baseline runs, which, with its build, takes longer.
        // If the baseline fails, or is stopped, their boot is cancelled, and awaited, as this scope ends. A stop once
        // it has passed cuts the boot short, which then throws.
        let simulators = try await simulatorWorkerSetup.make(for: plan.toRun.count, state: state)
        // The boot is given the dependency it uses, not the step.
        let booting = workerSimulators
        async let booted = SimulatorWorkerSetup.boot(simulators, on: booting)

        let initialTime = Date()
        let (testSuiteOutcome, testLog) = try await baseline(state: state)

        let timeAfterRunningTestSuite = Date()
        let timePerBuildTestCycle = DateInterval(
            start: initialTime,
            end: timeAfterRunningTestSuite
        ).duration

        guard testSuiteOutcome == .passed else {
            // A failing baseline is exactly when the user needs its output on disk, and nothing else
            // records it. It gets its own event rather than `.newTestLogAvailable`, which also
            // announces that a baseline was successfully determined and starts the progress bar or lines.
            events.send(
                .baselineTestFailed(MutationTestLog(
                    mutationPoint: .none,
                    testLog: testLog,
                    timePerBuildTestCycle: timePerBuildTestCycle,
                    remainingMutationPointsCount: .none
                ))
            )

            throw MuterError.mutationTestingAborted(
                reason: .baselineTestFailed(
                    log: testLog,
                    mutatedFilePaths: state.mutationMapping.map(\.filePath)
                )
            )
        }

        // One mutant's run shows every test it fails, not only the first.
        var muterConfiguration = state.selectedMutant == nil
            ? state.muterConfiguration
            : state.muterConfiguration.withoutStoppingAtFirstFailure()
        // A passing run can't show a failed test or a crash, so these tests print text shaped like one. Under a
        // mutant it could stop the run, or count a timed-out run killed, although every test passed, so such lines
        // don't count for this run, nor do the tests they show failing count among a mutant's failed tests. Checked
        // whether or not runs stop at their first failed test, but worth a notice only if they do, sent before the
        // baseline's log, which starts the progress bar or lines. Worker clones' baselines keep the configuration as
        // it was: a baseline is never stopped, and has no time limit.
        if let lookalike = FailedTestLine.first(inLog: testLog) ?? CrashLine.first(inLog: testLog) {
            if muterConfiguration.stopsAtFirstFailure {
                let reason = "the baseline run passed but printed a line that looks like a failed test or a crash:\n  "
                    + lookalike
                events.send(.stopAtFirstFailureTurnedOff(reason: reason))
            }
            muterConfiguration = muterConfiguration.withUnreliableFailedTestLines(printedIn: [testLog])
        }

        // A lone worker's simulator can be deleted here, once the baseline shows it wouldn't be faster.
        let checked = try await simulatorWorkerSetup.checkedAgainstTheBaseline(
            try await booted, log: testLog, destination: state.muterConfiguration.firstDestination
        )
        let pool = try await workers(
            testing: plan, on: checked, with: muterConfiguration, state: state, session: session
        )
        muterConfiguration = pool.configuration
        let workers = pool.count
        let (configuration, testRunSeconds) = try await mutantRuns(
            muterConfiguration,
            on: pool,
            testing: plan,
            baselineLog: testLog,
            baselineSeconds: timePerBuildTestCycle,
            state: state
        )
        // Only now, with nothing awaited before the results start: a stop during the timed test run, like one during
        // the baseline, has nothing to report.
        session.baselinePassed = true

        // Before the baseline's log, which starts the progress bar or lines, so the results file's path comes first.
        await startResults(
            await header(
                of: session,
                plan,
                state: state,
                configuration: configuration,
                baselineSeconds: timePerBuildTestCycle,
                testRunSeconds: testRunSeconds,
                workers: workers
            ),
            retiring: plan.retired,
            copying: reused,
            in: session,
            state: state
        )
        keepReused(reused, of: jobs, in: session, state: state)
        // A reuse with nothing left to test ran the baseline only to check the changed project, so it keeps its log
        // without the one that starts the progress bar or lines.
        guard !plan.toRun.isEmpty else {
            _ = fileManager.createFile(
                atPath: (state.loggingDirectory as NSString).appendingPathComponent(MutationTestLog.baselineFileName),
                contents: testLog.data(using: .utf8),
                attributes: nil
            )
            return
        }

        // The first estimate of the time left: every mutant to test, spread over the workers.
        events.send(
            .newTestLogAvailable(MutationTestLog(
                mutationPoint: .none,
                testLog: testLog,
                timePerBuildTestCycle: timePerBuildTestCycle,
                remainingMutationPointsCount: plan.toRun.count,
                workers: workers,
                testRunSeconds: testRunSeconds
            ))
        )

        let tasks = Self.tasks(plan.toRun, controlRunEvery: Self.controlRunEvery(state, configuration))
        if workers > 1 {
            try await testMutationsInParallel(
                jobs, tasks, workers: workers, using: state, configuration: configuration, session: session
            )
        } else {
            try await testMutations(jobs, tasks, using: state, configuration: configuration, session: session)
        }
    }

    /// The configuration `pool` tests `plan`'s mutants with, from `configuration`, the effective one: on the first
    /// xcodebuild worker, and with the default time limit unless one is configured, from the baseline's
    /// `baselineSeconds` or a timed test run. A SwiftPM run's mutants run their test bundles directly when a run that
    /// checks it, which times it too, passes (`runningTestBundlesDirectly`). Also the timed test run's seconds, if one
    /// passed.
    func mutantRuns(
        _ configuration: MuterConfiguration,
        on pool: SimulatorWorkerSetup.Workers,
        testing plan: ResumePlan,
        baselineLog: String,
        baselineSeconds: TimeInterval,
        state: AnyMutationTestState
    ) async throws -> (configuration: MuterConfiguration, testRunSeconds: TimeInterval?) {
        var configuration = configuration
        var testRunSeconds: TimeInterval?
        // A reuse with nothing left to test ran the baseline only to see that the changed tests pass. One mutant's run
        // saves no more than either costs, so its time limit is the configured one, or the baseline's default.
        let timesATestRun = !plan.toRun.isEmpty && state.selectedMutant == nil
        if configuration.buildSystem == .swift, timesATestRun {
            let direct = try await runningTestBundlesDirectly(configuration, baselineLog: baselineLog, state: state)
            configuration = direct.configuration
            // The run that checked the direct runs is a mutant's run with no mutant on, which needn't run again.
            if configuration.testSuiteTimeout == nil {
                testRunSeconds = direct.seconds
            }
        }
        configuration = Self.onFirstXcodeWorker(configuration, state, pool.xcodeWorkers.first)
        // An xcodebuild run's is on the first worker, as its mutants run, after any check runs, which paid for each
        // simulator's first install and launch.
        if testRunSeconds == nil, timesATestRun, configuration.testSuiteTimeout == nil,
           configuration.buildSystem != .unknown {
            testRunSeconds = try await timedTestRun.seconds(
                using: configuration, state: state, testOutput: testOutput(named: "timed test run", state: state)
            )
        }
        let limit = Self.defaultTimeout(testRunSeconds: testRunSeconds, baselineSeconds: baselineSeconds, on: pool)
        return (configuration.withDefaultTestSuiteTimeout(limit), testRunSeconds)
    }

    /// The workers that test `plan`'s mutants, with `configuration`, the effective one, said, with why fewer than asked
    /// for, once they are known. A clone costs a copy and about a baseline build, and a simulator a boot, so there are
    /// never more workers than mutants to test. An xcodebuild run's `simulators` are checked first, which can fall back
    /// to one worker on the test command's destination, and can make failed-test lines unreliable
    /// (`SimulatorWorkerSetup`). A lone worker's said to test on a simulator of its own only when it does.
    func workers(
        testing plan: ResumePlan,
        on simulators: SimulatorWorkerSetup.Simulators,
        with configuration: MuterConfiguration,
        state: AnyMutationTestState,
        session: TestingSession
    ) async throws -> SimulatorWorkerSetup.Workers {
        let workers = try await simulatorWorkerSetup.workers(
            min(configuration.workerCount, plan.toRun.count),
            on: simulators,
            configuration: configuration,
            state: state,
            session: session,
            testOutput: { testOutput(named: $0, state: state) }
        )
        if !plan.toRun.isEmpty {
            let choice = WorkerChoice(
                configuration,
                used: workers.count,
                mutantsToTest: plan.toRun.count,
                unsupportedReason: workers.unavailable,
                ownSimulator: !workers.xcodeWorkers.isEmpty
            )
            events.send(.workersChosen(choice))
        }
        return workers
    }

    /// The session's header, for testing `plan.toRun` of the jobs `session.keys` are of, with `configuration`, the
    /// effective one, on `workers` workers. A resumed session's says what it kept, and what its resume let through.
    func header(
        of session: TestingSession,
        _ plan: ResumePlan,
        state: AnyMutationTestState,
        configuration: MuterConfiguration,
        baselineSeconds: Double?,
        testRunSeconds: Double? = nil,
        workers: Int
    ) async -> ResultsHeader {
        let resume = state.resumeState
        // A resume's was probed before the copy, and what was checked is what is recorded.
        let sessionProvenance = if let recorded = resume?.provenance {
            recorded
        } else {
            await provenance(state.muterConfiguration)
        }
        return ResultsHeader(
            session: session.number,
            startedAt: session.startedAt,
            state: state,
            logDirectory: state.loggingDirectory,
            configuration: configuration,
            baselineSeconds: baselineSeconds,
            testRunSeconds: testRunSeconds,
            workers: workers,
            mutantsDiscovered: session.keys.count,
            mutantsToTest: plan.toRun.count,
            provenance: sessionProvenance,
            mutantsReused: resume == nil ? nil : plan.reused.count,
            waived: resume == nil ? nil : state.resumeWaived,
            forced: resume?.forced,
            reusedFrom: resume?.isReuse == true ? resume?.path : nil
        )
    }

    /// Which of the results file's results a resumed or reused run keeps for `jobs`, keyed by `keys`, and which jobs it
    /// tests; every job, for a run that does neither.
    static func plan(of jobs: [MutantJob], keyedBy keys: [MutantKey], state: AnyMutationTestState) -> ResumePlan {
        state.resumeState.map { resume in
            ResumePlan.make(
                keys: keys,
                snapshots: jobs.map(\.schema.snapshot),
                recorded: resume.recorded.latest,
                fileHashes: state.projectTree?.files ?? [:],
                workers: ResumePlan.workers(of: resume.recorded.headers),
                limits: ResumePlan.limits(of: resume.recorded.headers),
                limit: state.muterConfiguration.testSuiteTimeout,
                reusing: resume.isReuse ? state.reuseChanges : nil,
                leftOut: state.keysLeftOutOfTheSample
            )
        } ?? .everything(jobs.count)
    }

    /// The results `plan` keeps, by job index: as recorded for a resume, and for a reuse as the new results file
    /// records them (`MutantResult.reused`), each in its job's place, with where it was tested and what was let
    /// through since.
    func keptResults(_ plan: ResumePlan, of jobs: [MutantJob], state: AnyMutationTestState) -> [Int: MutantResult] {
        guard let resume = state.resumeState, resume.isReuse else { return plan.reused }
        return plan.reused.reduce(into: [:]) { kept, entry in
            let schema = jobs[entry.key].schema
            kept[entry.key] = entry.value.reused(
                from: resume.path,
                headers: resume.recorded.headers,
                in: 1,
                utf8Offset: schema.position.utf8Offset,
                switchID: schema.id,
                // What this run let through since the session that tested it, not since another session.
                despiteChanges: state.reuseChanges?[entry.value.session]?.waived.isEmpty == false
                    || !resume.forced.isEmpty
            )
        }
    }

    /// Keeps each of the `reused` results' outcomes in `session` by job index, built from its job as `record` builds a
    /// tested one's, with the tests its line names, and sends it to the reporter, so the Xcode format warns of every
    /// survivor. Never sends a test log, and comes before the baseline's log, so no progress bar or lines count it.
    func keepReused(
        _ reused: [Int: MutantResult],
        of jobs: [MutantJob],
        in session: TestingSession,
        state: AnyMutationTestState
    ) {
        for (index, result) in reused.sorted(by: { $0.key < $1.key }) {
            let outcome = Self.outcome(
                result.outcome,
                of: jobs[index],
                state: state,
                killingTests: .init(result),
                reusedFrom: result.reusedFrom,
                key: result.key,
                durationSeconds: result.durationSeconds
            )
            session.outcomes[index] = outcome
            session.reused += 1
            events.send(.newMutationTestOutcomeAvailable(outcome))
        }
    }

    /// The outcome of `job`'s mutant, which `testSuiteOutcome` says, with the tests that killed it, as the report shows
    /// it.
    static func outcome(
        _ testSuiteOutcome: TestSuiteOutcome,
        of job: MutantJob,
        state: AnyMutationTestState,
        killingTests: MutationTestOutcome.KillingTests?,
        reusedFrom: ReusedFrom? = nil,
        key: MutantKey,
        durationSeconds: Double
    ) -> MutationTestOutcome.Mutation {
        MutationTestOutcome.Mutation(
            testSuiteOutcome: testSuiteOutcome,
            mutationPoint: MutationPoint(
                mutationOperatorId: job.schema.mutationOperatorId,
                filePath: job.schema.filePath,
                position: job.schema.position
            ),
            mutationSnapshot: job.schema.snapshot,
            originalProjectDirectoryUrl: state.projectDirectoryURL,
            mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL,
            killingTests: killingTests,
            reusedFrom: reusedFrom,
            key: key,
            durationSeconds: durationSeconds
        )
    }

    /// Sends what mutation testing that stopped early tested, and the results a resumed session kept, for the partial
    /// report and the summary, once the baseline has passed. Before then there is nothing to report, and an abort says
    /// why.
    func sendEarlyEnd(
        of session: TestingSession,
        _ reason: ResultsEnd.Reason,
        detail: String?,
        state: AnyMutationTestState,
        testDuration: TimeInterval
    ) {
        guard session.baselinePassed else { return }
        events.send(
            .mutationTestingEndedEarly(EarlyEnd(
                reason: reason,
                detail: detail,
                outcome: MutationTestOutcome(
                    mutations: session.outcomesInJobOrder,
                    coverage: state.projectCoverage.limited(
                        to: state.changeSelection,
                        inCopyAt: state.mutatedProjectDirectoryURL
                    ),
                    coverageSkipped: state.runOptions.skipCoverage,
                    testDuration: testDuration,
                    newVersion: state.newVersion,
                    since: state.changeSelection,
                    shards: state.shardSelection?.scopeAlone,
                    sample: state.sampleSelection,
                    // As `report` of the results file judges it: a run can stop after its last mutant's result.
                    sampleIsCutShort: session.outcomesInJobOrder.count < session.keys.count,
                    mutant: state.selectedMutant?.description,
                    suspectTestThresholds: state.muterConfiguration.suspectTestThresholds,
                    controlRuns: Self.controlRuns(of: session, state: state),
                    projectPath: state.projectDirectoryURL.path,
                    mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
                    sourceDigests: Self.sourceDigests(of: state),
                    run: Self.runDetails(of: session, state: state)
                ),
                discovered: session.keys.count,
                reused: session.reused
            ))
        )
    }

    /// Every discovered mutant, in job order: file by file as discovery mapped them, and in each file in its order.
    static func jobs(of state: AnyMutationTestState) -> [MutantJob] {
        state.mutationMapping.flatMap { mutationMap in
            mutationMap.mutationSchemata.map { MutantJob(fileName: mutationMap.fileName, schema: $0) }
        }
    }

    /// `configuration`, for an xcodebuild project, with its mutants' runs on the first xcodebuild worker, as one worker
    /// alone has it: on `worker`'s simulator when the run made one for its lone worker
    /// (`SimulatorWorkerSetup.Workers.xcodeWorkers`), else on the test command's destination. Either way they test
    /// from `muter.xctestrun`, and keep their derived data beside the mutated project rather than in
    /// `~/Library/Developer/Xcode/DerivedData`, where every run made a new folder. They turn test diagnostics off if
    /// the test command takes the option.
    static func onFirstXcodeWorker(
        _ configuration: MuterConfiguration,
        _ state: AnyMutationTestState,
        _ worker: MuterConfiguration.XcodeWorker? = nil
    ) -> MuterConfiguration {
        guard configuration.buildSystem == .xcodebuild else { return configuration }
        return configuration.forXcodeWorker(worker ?? MuterConfiguration.XcodeWorker(
            testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: 0),
            derivedData: MuterConfiguration.XcodeWorker.derivedData(ofWorker: 0, in: state.mutatedProjectDirectoryURL),
            testDiagnosticsOff: state.testDiagnosticsCanBeTurnedOff
        ))
    }

    /// Runs `tasks`, in their order, one at a time in the mutated project: the jobs' mutants, and the control runs
    /// among them.
    func testMutations(
        _ jobs: [MutantJob],
        _ tasks: [PoolTask],
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        var buildErrors = 0
        let controlRuns = (Self.controlRunCount(in: tasks), Self.controlRunEvery(state, configuration))
        events.send(.mutantRunsStarted)
        heartbeat.begin(workers: 1, at: instant())
        let beating = beat()
        defer { beating.cancel() }

        for task in tasks {
            try Task.checkCancellation()
            let index: Int
            switch task {
            case let .mutant(mutant):
                index = mutant
            case let .control(number):
                let finished = try await Self.runControl(
                    number,
                    on: (0, PoolWorker(directory: state.mutatedProjectDirectoryURL, configuration: configuration)),
                    workingDirectory: nil,
                    from: state.projectXCTestRun,
                    fileName: testOutput(named: Self.place(ofControlRun: number), state: state),
                    using: (ioDelegate, instant, heartbeat)
                )
                try Self.throwIfCancelled(finished.run)
                try recordControlRun(
                    finished,
                    number: number,
                    of: controlRuns,
                    using: state,
                    configuration: configuration,
                    session: session
                )
                continue
            }
            let job = jobs[index]
            try await Self.switchOn(
                job,
                from: state.projectXCTestRun,
                in: state.mutatedProjectDirectoryURL,
                for: configuration,
                using: ioDelegate
            )

            let finished = await FinishedRun.make(
                index: index,
                worker: 0,
                configuration: configuration,
                instant: instant,
                heartbeat: (heartbeat, place: Self.place(of: job))
            ) {
                await ioDelegate.runTestSuite(
                    withSchemata: job.schema,
                    using: configuration,
                    savingResultsIntoFileNamed: testOutput(named: logFileName(forJobAt: index, job), state: state)
                )
            }
            try Self.throwIfCancelled(finished.run)

            try record(
                finished,
                of: job,
                using: state,
                configuration: configuration,
                session: session,
                buildErrors: &buildErrors
            )
        }
    }

    /// Sends the mutants under way whenever `heartbeat` says none has finished for a while, until cancelled. It reads
    /// the clock only once a wait ends, the first a whole interval, so it never moves a test's scripted clock on.
    func beat() -> Task<Void, Never> {
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
    /// The clones are kept in `session`, and `run(with:)` removes them once the end line is written. Once mutation
    /// testing is cancelled, no clone is made, no mutant starts, and none that returns is recorded.
    func testMutationsInParallel(
        _ jobs: [MutantJob],
        _ tasks: [PoolTask],
        workers: Int,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        // A clone costs a copy and about one baseline build, which a stopped run would only throw away.
        try Task.checkCancellation()
        let pool: [PoolWorker]
        if configuration.buildSystem == .xcodebuild {
            pool = session.xcodeWorkers.prefix(workers).map {
                PoolWorker(directory: state.mutatedProjectDirectoryURL, configuration: configuration.forXcodeWorker($0))
            }
        } else {
            pool = try await cloneWorkers(workers, using: state, configuration: configuration, session: session)
        }

        var buildErrors = 0
        var timeouts: [Int] = []
        let controlRuns = (Self.controlRunCount(in: tasks), Self.controlRunEvery(state, configuration))
        events.send(.mutantRunsStarted)
        heartbeat.begin(workers: pool.count, at: instant())
        let beating = beat()
        defer { beating.cancel() }

        try await runPool(
            tasks,
            of: jobs,
            on: pool,
            switchingOnFrom: state.projectXCTestRun,
            outputNamed: { testOutput(named: logFileName(forJobAt: $0, $1), state: state) },
            controlOutputNamed: { testOutput(named: Self.place(ofControlRun: $0), state: state) },
            recordingControlRun: { number, finished in
                try recordControlRun(
                    finished,
                    number: number,
                    of: controlRuns,
                    using: state,
                    configuration: configuration,
                    session: session
                )
            },
            recording: { finished in
                try record(
                    finished,
                    of: jobs[finished.index],
                    using: state,
                    configuration: configuration,
                    session: session,
                    buildErrors: &buildErrors
                )
                // A run the limit stopped whose log shows a failure is a kill, which another run wouldn't change.
                if finished.run.outcome == .timeout {
                    timeouts.append(finished.index)
                }
            }
        )
        try await rerunTimeouts(
            timeouts.sorted(), of: jobs, on: pool, using: state, configuration: configuration, session: session
        )
    }

    /// Tests the jobs at `indices` again, whose runs timed out, in job order, on the first quarter of `workers` at
    /// once, at least one, never more than `indices`: with every worker's tests competing for the same cores, a slow
    /// test can pass the limit that it keeps to under less load. The limit is `configuration`'s, the first runs', which
    /// every worker's shares, so a mutant that loops forever times out again. Each run's line follows its first run's,
    /// which it replaces, and its events don't count in the progress, which counted the first run (`recordRerun`).
    func rerunTimeouts(
        _ indices: [Int],
        of jobs: [MutantJob],
        on workers: [PoolWorker],
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        guard !indices.isEmpty else { return }
        try Task.checkCancellation()
        let reruns = TimeoutReruns(
            count: indices.count,
            workers: min(max(workers.count / 4, 1), indices.count),
            limitSeconds: configuration.testSuiteTimeout
        )
        events.send(.timeoutRerunsStarted(reruns))
        var tally = TimeoutRerunTally(reruns)
        try await runPool(
            indices.map(PoolTask.mutant),
            of: jobs,
            on: Array(workers.prefix(reruns.workers)),
            switchingOnFrom: state.projectXCTestRun,
            outputNamed: { testOutput(named: logFileName(forRerunOfJobAt: $0, $1), state: state) },
            recording: { finished in
                try recordRerun(
                    finished,
                    of: jobs[finished.index],
                    tally: &tally,
                    using: state,
                    configuration: configuration,
                    session: session
                )
            }
        )
        events.send(.timeoutRerunsFinished(tally))
    }

    /// `count` SwiftPM workers: the mutated project, and a clone of it for each other, built, and kept in `session`.
    func cloneWorkers(
        _ count: Int,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws -> [PoolWorker] {
        let clones: [URL]
        do {
            clones = try await makeWorkerDirectories(state.mutatedProjectDirectoryURL, count - 1)
        } catch {
            // Stopping the run kills a `cp` under way, which then fails.
            try Task.checkCancellation()
            throw error
        }
        session.clones = clones
        try await buildWorkerDirectories(clones, using: state)
        return ([state.mutatedProjectDirectoryURL] + clones).map {
            PoolWorker(directory: $0, configuration: configuration)
        }
    }

    /// Builds each worker clone once, by running the baseline test command in it. A clone is copied
    /// after the mutated project was built, and `swift test --skip-build` would otherwise run the test
    /// binaries built there: `#filePath` and every other path compiled into them would still point into
    /// the mutated project, so tests that write files next to their sources would share those files
    /// across workers, fail each other, and kill mutants they never tested. A clone whose baseline
    /// doesn't pass stops the run, naming the worker: the same command just passed in the mutated
    /// project, so the configuration isn't what's wrong. A run stopped meanwhile blames no clone:
    /// stopping kills the builds under way, which then fail.
    func buildWorkerDirectories(_ clones: [URL], using state: AnyMutationTestState) async throws {
        let configuration = state.muterConfiguration
        let runs = await withTaskGroup(of: (worker: Int, outcome: TestSuiteOutcome, testLog: String).self) { group in
            for (index, clone) in clones.enumerated() {
                let fileName = testOutput(named: "baseline run worker \(index + 1)", state: state)
                // A clone's build is given the values and the dependency it uses, not the step or the state.
                group.addTask { [ioDelegate] in
                    let run = await ioDelegate.benchmarkTests(
                        using: configuration,
                        savingResultsIntoFileNamed: fileName,
                        workingDirectory: clone
                    )
                    return (index + 1, run.outcome, run.testLog)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        try Task.checkCancellation()
        // A failed one's log is what says why the run stopped, and the abort message is all that shows it otherwise.
        for run in runs.sorted(by: { $0.worker < $1.worker }) {
            fileManager.keepLog(run.testLog, named: "baseline run worker \(run.worker).log", state: state)
        }

        // The lowest-numbered failure, so the same worker is named whichever build finished first.
        if let failed = runs.filter({ $0.outcome != .passed }).min(by: { $0.worker < $1.worker }) {
            throw MuterError.mutationTestingAborted(
                reason: .workerBaselineTestFailed(
                    worker: failed.worker,
                    directory: clones[failed.worker - 1].path,
                    log: failed.testLog
                )
            )
        }
    }

    /// `configuration` with mutants' tests run without `swift test`, if a run of them with no mutant on, once the
    /// baseline has built the project, passes and runs the tests the baseline's log shows, with how long it took. Else
    /// `configuration` as it is, and why, unless it isn't worth saying. A run that fails the check keeps its log.
    func runningTestBundlesDirectly(
        _ configuration: MuterConfiguration,
        baselineLog: String,
        state: AnyMutationTestState
    ) async throws -> (configuration: MuterConfiguration, seconds: TimeInterval?) {
        let notDirect = { (reason: String) in
            events.send(.testBundlesNotRunDirectly(reason: reason))
            return (configuration, TimeInterval?.none)
        }
        let direct: DirectTestRun
        switch await directTestRun(configuration, state.mutatedProjectDirectoryURL) {
        case let .success(probed):
            direct = probed
        case let .failure(unavailable):
            try Task.checkCancellation()
            return unavailable.reason.map(notDirect) ?? (configuration, nil)
        }
        try Task.checkCancellation()
        if DirectTestRun.ranXCTestTests(in: baselineLog) {
            return notDirect("the baseline ran XCTest tests, which only `swift test` runs")
        }

        let directConfiguration = configuration.withDirectTestRun(direct)
        let start = instant()
        let (outcome, testLog) = await ioDelegate.runTestsWithoutBuilding(
            using: directConfiguration,
            savingResultsIntoFileNamed: testOutput(named: "direct test run", state: state)
        )
        // Stopping the run kills this run too, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()
        let seconds = seconds(since: start)
        if let reason = DirectTestRun.whyNot(baselineLog: baselineLog, outcome: outcome, log: testLog) {
            fileManager.keepLog(testLog, named: "direct test run.log", state: state)
            return notDirect(reason + " (its log is direct test run.log)")
        }
        fileManager.keepLog(testLog, named: "timed test run.log", state: state)
        return (directConfiguration, seconds)
    }

    /// The seconds from `start` to now, on the monotonic clock.
    func seconds(since start: DispatchTime) -> TimeInterval {
        Self.seconds(from: start, to: instant())
    }

    /// Records `finished`, the run of `job`'s mutant (`keep`), sends its events, and aborts after
    /// `buildErrorsThreshold` build errors in a row, not counting a mutant that an earlier session recorded as one
    /// (`TestingSession.earlierBuildErrors`). The outcome is kept before the abort, so mutation testing that stops
    /// there still has it. The run of the one mutant `--mutant` tests also sends what the end of the run prints of it.
    func record(
        _ finished: FinishedRun,
        of job: MutantJob,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession,
        buildErrors: inout Int
    ) throws {
        let (outcome, mutationLog) = try keep(
            finished, of: job, rerun: nil, using: state, configuration: configuration, session: session
        )

        events.send(.newMutationTestOutcomeAvailable(outcome))

        events.send(.newTestLogAvailable(mutationLog))

        if state.selectedMutant != nil {
            events.send(
                .oneMutantTested(OneMutantRun(
                    key: session.keys[finished.index],
                    switchID: job.schema.id,
                    snapshot: job.schema.snapshot,
                    change: change(of: job.schema, key: session.keys[finished.index], in: outcome, state: state),
                    outcome: finished.run.outcome,
                    killingTests: outcome.killingTests,
                    seconds: finished.seconds,
                    timeoutSeconds: configuration.testSuiteTimeout,
                    testLog: finished.run.testLog,
                    logPath: state.loggingDirectory.isEmpty
                        ? nil
                        : (state.loggingDirectory as NSString).appendingPathComponent(mutationLog.keptFileName),
                    mutatedProject: state.mutatedProjectDirectoryURL.path,
                    buildSystem: configuration.buildSystem,
                    testCommand: [configuration.testCommandExecutable] + configuration.testCommandArguments
                ))
            )
        }

        if finished.run.outcome != .buildError {
            buildErrors = 0
        } else if !session.earlierBuildErrors.contains(finished.index) {
            buildErrors += 1
        }
        if buildErrors >= buildErrorsThreshold {
            throw MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)
        }
    }

    /// What `schema`'s mutant, keyed `key`, changes, as `MutantDiff` finds it in its original file, `outcome`'s, never
    /// the copy, whose code holds every switch. As its snapshot gives it when the original file can't be read, or can't
    /// be told to be as the mutant was found in it: a test plan's file that changed since the plan was made, let
    /// through by `--plan-ignoring`, and one that a plan doesn't record, as a plan in format 0 records none.
    func change(
        of schema: MutationSchema,
        key: MutantKey,
        in outcome: MutationTestOutcome.Mutation,
        state: AnyMutationTestState
    ) -> [String] {
        let fallback = MutantDiff.fallback(snapshot: schema.snapshot, mutationOperatorId: schema.mutationOperatorId)
        guard let data = fileManager.contents(atPath: outcome.originalProjectPath),
              let original = String(data: data, encoding: .utf8)
        else { return fallback }
        if let plan = state.testPlan {
            // A file with mutants that is a symbolic link is recorded by what its link's file held.
            let planned = plan.linkedFiles?[key.path] ?? plan.sources?.files[key.path]
            guard planned == FileDigest.sha256(of: data) else { return fallback }
        }
        return MutantDiff.lines(
            original: original,
            snapshot: schema.snapshot,
            mutationOperatorId: schema.mutationOperatorId,
            line: key.line,
            column: key.column
        ) ?? fallback
    }

    /// Records `finished`, the run that tested `job`'s timed-out mutant again (`keep`), counts it in `tally`, and sends
    /// its event. Never its outcome's or its log's events, which would count the mutant in the progress again, and
    /// never toward the build errors in a row: a build error here says nothing of the mutants before it.
    func recordRerun(
        _ finished: FinishedRun,
        of job: MutantJob,
        tally: inout TimeoutRerunTally,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) throws {
        let (outcome, mutationLog) = try keep(
            finished,
            of: job,
            rerun: MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: tally.reruns.workers),
            using: state,
            configuration: configuration,
            session: session
        )
        tally.add(outcome.testSuiteOutcome)
        events.send(
            .timeoutRerunFinished(TimeoutRerun(
                rerun: outcome,
                log: mutationLog,
                seconds: finished.seconds,
                number: tally.rerun,
                count: tally.reruns.count
            ))
        )
    }

    /// Writes `finished`'s result, the run of `job`'s mutant, or its `rerun`, to the results file, keeps its outcome in
    /// `session`, and returns it with its log, kept under the name the line gives it. The result is written first, so
    /// it is on disk before anything else happens. `configuration` is the effective one, whose baseline may have made
    /// failed-test lines unreliable. A run on a simulator that is gone is never recorded, and aborts mutation testing
    /// (`abortingIfTheSimulatorIsGone`). A run the simulator failed to launch before this one is sent only once this
    /// one's result is written (`sendingTheRunTheSimulatorFailedToLaunch`).
    func keep(
        _ finished: FinishedRun,
        of job: MutantJob,
        rerun: MutantResult.Rerun?,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) throws -> (outcome: MutationTestOutcome.Mutation, log: MutationTestLog) {
        // The failed tests are worked out here, not in `write`'s autoclosure: the outcome needs them without a results
        // file, or after a failed write. One scan of the log serves both.
        let failures = MutantResult.failedTests(of: finished.run, ignoring: configuration.failedTestLookalikes)
        let key = session.keys[finished.index]
        let outcome = Self.outcome(
            finished.run.outcome,
            of: job,
            state: state,
            killingTests: .init(failures, endedBy: finished.run.ending),
            key: key,
            durationSeconds: MutantResult.recordedSeconds(finished.seconds)
        )
        let log = rerun == nil ? MutationTestLog.keptFileName(for: key) : MutationTestLog.rerunFileName(for: key)
        try abortingIfTheSimulatorIsGone(in: finished, logName: log, configuration: configuration, state: state)
        write(
            MutantResult(
                key: key,
                schema: job.schema,
                finished: finished,
                failures: failures,
                session: session.number,
                finishedAt: now(),
                log: log,
                fileSHA256: state.projectTree?.files[key.path],
                rerun: rerun
            ),
            in: session,
            isAMutant: true
        )
        session.outcomes[finished.index] = outcome
        sendingTheRunTheSimulatorFailedToLaunch(before: finished, of: outcome, logName: log)

        let mutationLog = MutationTestLog(
            mutationPoint: outcome.point,
            testLog: finished.run.testLog,
            timePerBuildTestCycle: .none,
            remainingMutationPointsCount: .none,
            keptFileName: log
        )
        return (outcome, mutationLog)
    }

    /// If the simulator failed to launch the run before `finished`, sends that run with `outcome`, `finished`'s, and
    /// its log, which is kept beside `logName`, `finished`'s. Called once `finished`'s result is written, so the
    /// results file has its line before the console says the mutant ran again or the first run's log is kept.
    func sendingTheRunTheSimulatorFailedToLaunch(
        before finished: FinishedRun,
        of outcome: MutationTestOutcome.Mutation,
        logName: String
    ) {
        guard let failure = finished.launchFailure else { return }
        let log = MutationTestLog(
            mutationPoint: outcome.point,
            testLog: failure.testLog,
            timePerBuildTestCycle: .none,
            remainingMutationPointsCount: .none,
            keptFileName: MutationTestLog.launchFailedFileName(for: logName)
        )
        events.send(
            .runRepeatedAfterLaunchFailure(RepeatedRun(
                mutant: outcome, worker: finished.worker, line: failure.line, log: log
            ))
        )
    }

    /// The baseline run's outcome and log. A baseline the simulator failed to launch says nothing about the tests
    /// either, so it runs once more, as a mutant's run does (`SimulatorTrouble.launch`), and the first run's log is
    /// sent to be kept, whatever the second comes to. The caller times both runs: the first paid for the build. A stop
    /// throws.
    private func baseline(state: AnyMutationTestState) async throws -> (outcome: TestSuiteOutcome, testLog: String) {
        let (baseline, launchFailure) = await TestRun.launchedOnceMore(ifNeededWith: state.muterConfiguration) {
            let (outcome, testLog) = await ioDelegate.benchmarkTests(
                using: state.muterConfiguration,
                savingResultsIntoFileNamed: testOutput(named: "baseline run", state: state)
            )
            return TestRun(outcome: outcome, testLog: testLog)
        }
        // Stopping the run kills the baseline run, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()
        if let launchFailure {
            let log = MutationTestLog(
                mutationPoint: .none,
                testLog: launchFailure.testLog,
                timePerBuildTestCycle: .none,
                remainingMutationPointsCount: .none,
                keptFileName: MutationTestLog.launchFailedFileName(for: MutationTestLog.baselineFileName)
            )
            events.send(.baselineRepeatedAfterLaunchFailure(line: launchFailure.line, log: log))
        }
        return (baseline.outcome, baseline.testLog)
    }

    /// The file a mutant's run writes its output to while it runs. Its job's number comes first, so two runs under way
    /// at once never share one, as mutants in same-named files at the same place, or a repeated mutant, otherwise
    /// would: the first to finish would remove the file the other still has to read.
    func logFileName(forJobAt index: Int, _ job: MutantJob) -> String {
        "\(index)_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_\(job.schema.position).log"
    }

    /// The file the run that tests a timed-out mutant again writes its output to while it runs, which the first run's
    /// output, if a stop left it, never shares.
    func logFileName(forRerunOfJobAt index: Int, _ job: MutantJob) -> String {
        "\(index)_rerun_\(job.fileName)_\(job.schema.mutationOperatorId.rawValue)_\(job.schema.position).log"
    }

    /// Where the test run whose log is `name` writes its output while it runs: `testOutputFolderName` in the run's
    /// log folder, or, without one, as a state that bypasses the handler has, the current directory.
    func testOutput(named name: String, state: AnyMutationTestState) -> String {
        guard !state.loggingDirectory.isEmpty else { return name }
        return (state.loggingDirectory as NSString)
            .appendingPathComponent(Self.testOutputFolderName)
            .appending("/\(name)")
    }

    /// Deletes the worker simulators an earlier xcodebuild run of the project left, stopped at once, killed or crashed,
    /// with those of any run that has ended. Booted, each holds memory, which the baseline could use. Under the mutated
    /// project's lock, so no run of this project is under way.
    func sweepLeftoverSimulators(_ state: AnyMutationTestState) async {
        guard state.muterConfiguration.buildSystem == .xcodebuild else { return }
        await workerSimulators.sweep(state.mutatedProjectDirectoryURL)
    }

    /// Removes the run's test-output folder if it is empty, as it is once every run has been read back, so a finished
    /// run's log folder holds only the logs it keeps. A stop leaves the folder, with the output of the runs under way.
    func removeTestOutputFolderIfEmpty(_ state: AnyMutationTestState) {
        guard !state.loggingDirectory.isEmpty else { return }
        let folder = (state.loggingDirectory as NSString).appendingPathComponent(Self.testOutputFolderName)
        removeFolderIfEmpty(atPath: folder, fileManager: fileManager)
    }
}

/// The run's results file: a header once the baseline passes, or at once for a resumed run with nothing left to test,
/// a line for each tested mutant as it finishes, and an end line however mutation testing ends.
private extension PerformMutationTesting {
    /// Creates the results file in the run's log folder, and writes `header` to it. Without one the run goes on: the
    /// report at the end doesn't need it. A state without a log folder, which a test that bypasses the handler
    /// makes, writes none, and the header isn't made.
    ///
    /// A resumed run instead writes `header`, then a `retired` line of the `retiring` keys, to the stopped run's file,
    /// which it opened before the copy. Once both are written, it leaves a note naming the file in its own log folder,
    /// and announces the file. It is attached to the session only now: before its header, no line of the session's
    /// would belong to one. A run that reuses an earlier run's results writes a new file, as a first session does,
    /// with the `copying` results after its header, all at once, and copies their logs into its log folder, before it
    /// announces the file.
    ///
    /// The file becomes the session's as its first lines, the header and any `retired` line, are written, in one write
    /// while the session's lock is held. A stop at once then ends the session after both, or, before them, writes
    /// nothing, and a run killed as it starts leaves both or neither, unless the write is cut short, which leaves a
    /// cut-off last line that readers skip. Written one after the other, a kill or an end line between them would leave
    /// the header without the `retired` line, and the file would stand by the results the session retires until the
    /// next session's. `header` probes the toolchain, so it is made before any of this.
    func startResults(
        _ header: @autoclosure () async -> ResultsHeader,
        retiring retired: [MutantKey],
        copying reused: [Int: MutantResult],
        in session: TestingSession,
        state: AnyMutationTestState
    ) async {
        if let resume = state.resumeState, let file = resume.file {
            var firstLines: [any Encodable] = [await header()]
            // Without it, the file would still stand by the earlier results this session doesn't keep.
            if !retired.isEmpty {
                firstLines.append(ResultsRetired(session: session.number, keys: retired))
            }
            guard sayingAFailure(session.startResults(in: file, writing: firstLines), in: session) else { return }
            session.header = firstLines.first as? ResultsHeader
            session.resultsPath = resume.path
            leaveANote(pointingTo: resume.path, session: session.number, in: state.loggingDirectory)
            events.send(.resultsFileCreated(path: resume.path))
            return
        }
        let loggingDirectory = state.loggingDirectory
        guard !loggingDirectory.isEmpty else { return }
        let headerLine = await header()
        do {
            let results = try resultsFiles.create(in: loggingDirectory)
            guard sayingAFailure(session.startResults(in: results, writing: [headerLine]), in: session) else { return }
            session.header = headerLine
            session.resultsPath = results.path
            if let resume = state.resumeState, resume.isReuse {
                let lines = reused.sorted { $0.key < $1.key }.map(\.value)
                guard sayingAFailure(session.append(contentsOf: lines), in: session) else { return }
                copyLogs(of: lines, from: resume, into: loggingDirectory)
            }
            events.send(.resultsFileCreated(path: results.path))
        } catch {
            events.send(.resultsFileUnavailable(reason: "\(error)"))
        }
    }

    /// Leaves a note in this session's log folder, `ResultsFile.noteFileName`, that names the results file at `path` it
    /// adds to, which is in the first session's folder, so that the folder can be given in the file's place. A state
    /// without a log folder leaves none. A note that can't be written is left out: the console names the file too.
    func leaveANote(pointingTo path: String, session: Int, in loggingDirectory: String) {
        guard !loggingDirectory.isEmpty else { return }
        _ = fileManager.createFile(
            atPath: (loggingDirectory as NSString).appendingPathComponent(ResultsFile.noteFileName),
            contents: Data(ResultsFile.note(pointingTo: path, session: session).utf8),
            attributes: nil
        )
    }

    /// Copies each of the `reused` results' kept logs from the folder of the session that recorded it in `resume`'s
    /// file into `loggingDirectory`, under the same name, which its new line names. A log that isn't there any more, or
    /// can't be copied, is left out: the result doesn't depend on it.
    func copyLogs(of reused: [MutantResult], from resume: ResumeState, into loggingDirectory: String) {
        let folders = Dictionary(
            resume.recorded.headers.map { ($0.session, $0.logDirectory) },
            uniquingKeysWith: { _, last in last }
        )
        for result in reused {
            guard let recorded = resume.recorded.latest[result.key], let folder = folders[recorded.session] else {
                continue
            }
            let source = (folder as NSString).appendingPathComponent(recorded.log)
            let destination = (loggingDirectory as NSString).appendingPathComponent(result.log)
            try? fileManager.copyItem(atPath: source, toPath: destination)
        }
    }

    /// Writes the session's end line, and closes its results file, which releases the file's lock.
    func endResults(
        of session: TestingSession,
        _ reason: ResultsEnd.Reason,
        detail: String? = nil,
        testDuration: TimeInterval
    ) {
        let written = session.end { recorded in
            Self.endLine(
                of: session,
                reason,
                detail: detail,
                testDuration: testDuration,
                recorded: recorded,
                endedAt: now()
            )
        }
        sayingAFailure(written, in: session)
    }
}

extension PerformMutationTesting {
    /// Each project file's SHA-256 as it was tested, by its path in the project, which the reports check a file
    /// against before showing a mutant's line from it: the project tree's, or for a run of a test plan, whose tree is
    /// its rewritten copy, what the plan recorded of the project when it was made. nil for a plan in format 0, which
    /// records nothing.
    static func sourceDigests(of state: AnyMutationTestState) -> [String: String]? {
        guard let plan = state.testPlan else { return state.projectTree?.files }
        // A file with mutants that is a symbolic link is recorded by what its link's file held.
        return plan.sources.map { $0.files.merging(plan.linkedFiles ?? [:]) { _, linked in linked } }
    }

    /// Where `session`'s results came from, once its header is written to its results file: that file, with the
    /// headers of the sessions a resumed run's file holds before it. nil once a write to the file has failed: the file
    /// then lacks some of the session's results, and the run no longer names it.
    static func runDetails(of session: TestingSession, state: AnyMutationTestState) -> RunDetails? {
        guard !session.saidResultsUnwritable, let header = session.header, let path = session.resultsPath else {
            return nil
        }
        let earlier = state.resumeState.map { $0.isReuse ? [] : $0.recorded.headers } ?? []
        return RunDetails(of: [(path, earlier + [header])])
    }
}
