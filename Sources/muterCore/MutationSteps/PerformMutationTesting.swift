import Foundation
import SwiftSyntax

struct PerformMutationTesting: MutationStep {
    @Dependency(\.ioDelegate)
    private var ioDelegate: MutationTestingIODelegate
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.now)
    private var now: Now
    @Dependency(\.instant)
    private var instant: Instant
    @Dependency(\.resultsFiles)
    private var resultsFiles: ResultsFileOpening
    @Dependency(\.provenance)
    private var provenance: ProvenanceProbe
    @Dependency(\.interruption)
    private var interruption: InterruptionRecord
    @Dependency(\.directTestRun)
    private var directTestRun: DirectTestRunProbe

    private let buildErrorsThreshold: Int = 5

    /// The folder in the run's log folder that each test run writes its output to while it runs. Never the mutated
    /// project or a clone, where a test that lists the package's files, or asks git for untracked ones, would see it.
    /// Each run's file goes once its log is read back (`MutationTestingDelegate`), and the log folder keeps its own
    /// copy, so only the output of runs a stop cut short stays.
    static let testOutputFolderName = "running"

    /// With no `mutationTestTimeout`, a SwiftPM mutant's test run may take this many times one timed run of its test
    /// command with no mutant on, and once more for each worker beyond the first, but never less than
    /// `minimumTestRunTimeout` seconds. Every worker's tests compete for the same cores. A mutant that makes the code
    /// loop forever then costs a few test runs, not the minutes a build takes.
    static let testRunTimeoutMultiplier: TimeInterval = 5
    static let minimumTestRunTimeout: TimeInterval = 20
    /// With no `mutationTestTimeout` and no timed test run, as for another build system, a mutant's test run may take
    /// this many times the baseline run, build included, but never less than `minimumDefaultTimeout` seconds.
    static let defaultTimeoutMultiplier: TimeInterval = 3
    static let minimumDefaultTimeout: TimeInterval = 10

    /// The default time limit for a mutant's test run on `workers` workers, from one timed run of its test command.
    static func defaultTimeout(testRunSeconds: TimeInterval, workers: Int) -> TimeInterval {
        let multiplier = testRunTimeoutMultiplier + Double(max(workers, 1) - 1)
        return max(testRunSeconds * multiplier, minimumTestRunTimeout)
    }

    /// How long stopping at once waits to write the end line while a line is being written, in seconds.
    static let endLineWaitAtOnce: TimeInterval = 2

    /// Clones the mutated project for each extra parallel worker, and removes the clones afterwards.
    /// Injected so tests don't touch the disk.
    private let makeWorkerDirectories: (_ mutatedProject: URL, _ count: Int) async throws -> [URL]
    private let removeWorkerDirectories: (_ directories: [URL]) -> Void

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
        // which holds one run's at most. They go first: they take no time.
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
            mutant: state.selectedMutant?.description
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

        let initialTime = Date()
        let (testSuiteOutcome, testLog) = await ioDelegate.benchmarkTests(
            using: state.muterConfiguration,
            savingResultsIntoFileNamed: testOutput(named: "baseline run", state: state)
        )
        // Stopping the run kills the baseline run, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()

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
        // don't count for this run. Checked whether or not runs stop at their first failed test, but worth a notice
        // only if they do, sent before the baseline's log, which starts the progress bar or lines. Worker clones'
        // baselines keep the configuration as it was: a baseline is never stopped, and has no time limit.
        if let lookalike = FailedTestLine.first(inLog: testLog) ?? CrashLine.first(inLog: testLog) {
            if muterConfiguration.stopsAtFirstFailure {
                let reason = "the baseline run passed but printed a line that looks like a failed test or a crash:\n  "
                    + lookalike
                events.send(.stopAtFirstFailureTurnedOff(reason: reason))
            }
            muterConfiguration = muterConfiguration.withUnreliableFailedTestLines()
        }

        // A clone costs a copy and about a baseline build, so there are never more workers than mutants to test.
        let workers = min(muterConfiguration.workerCount, plan.toRun.count)
        if !plan.toRun.isEmpty {
            let choice = WorkerChoice(muterConfiguration, used: workers, mutantsToTest: plan.toRun.count)
            events.send(.workersChosen(choice))
        }
        var testRunSeconds: TimeInterval?
        // A reuse with nothing left to test ran the baseline only to see that the changed tests pass. One mutant's run
        // saves no more than either costs, so its time limit is the configured one, or the baseline's default.
        if muterConfiguration.buildSystem == .swift, !plan.toRun.isEmpty, state.selectedMutant == nil {
            let direct = try await runningTestBundlesDirectly(muterConfiguration, baselineLog: testLog, state: state)
            muterConfiguration = direct.configuration
            // The run that checked the direct runs is a mutant's run with no mutant on, which needn't run again.
            if muterConfiguration.testSuiteTimeout == nil {
                testRunSeconds = direct.seconds
                if testRunSeconds == nil {
                    testRunSeconds = try await timeTestRun(using: muterConfiguration, state: state)
                }
            }
        }
        let configuration = Self.onFirstXcodeWorker(muterConfiguration, state).withDefaultTestSuiteTimeout(
            testRunSeconds.map { Self.defaultTimeout(testRunSeconds: $0, workers: workers) }
                ?? max(timePerBuildTestCycle * Self.defaultTimeoutMultiplier, Self.minimumDefaultTimeout)
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

        if workers > 1 {
            try await testMutationsInParallel(
                jobs, plan.toRun, workers: workers, using: state, configuration: configuration, session: session
            )
        } else {
            try await testMutations(jobs, plan.toRun, using: state, configuration: configuration, session: session)
        }
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
                reusedFrom: result.reusedFrom
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
        reusedFrom: ReusedFrom? = nil
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
            reusedFrom: reusedFrom
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
                    mutant: state.selectedMutant?.description
                ),
                discovered: session.keys.count,
                reused: session.reused
            ))
        )
    }

    struct MutantJob {
        let fileName: FileName
        let schema: MutationSchema
    }

    /// Every discovered mutant, in job order: file by file as discovery mapped them, and in each file in its order.
    static func jobs(of state: AnyMutationTestState) -> [MutantJob] {
        state.mutationMapping.flatMap { mutationMap in
            mutationMap.mutationSchemata.map { MutantJob(fileName: mutationMap.fileName, schema: $0) }
        }
    }

    /// `configuration`, for an xcodebuild project, with its mutants' runs on the first xcodebuild worker, the only one
    /// there is: they test from `muter.xctestrun`, on the test command's destination, and keep their derived data
    /// beside the mutated project rather than in `~/Library/Developer/Xcode/DerivedData`, where every run made a new
    /// folder. They turn test diagnostics off if the test command takes the option.
    static func onFirstXcodeWorker(
        _ configuration: MuterConfiguration,
        _ state: AnyMutationTestState
    ) -> MuterConfiguration {
        guard configuration.buildSystem == .xcodebuild else { return configuration }
        return configuration.forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: MutationTestingDelegate.muterTestRunFileName,
            derivedData: MuterConfiguration.XcodeWorker.derivedData(ofWorker: 0, in: state.mutatedProjectDirectoryURL),
            testDiagnosticsOff: state.testDiagnosticsCanBeTurnedOff
        ))
    }

    /// Tests the jobs at `indices`, in their order, one at a time in the mutated project.
    func testMutations(
        _ jobs: [MutantJob],
        _ indices: [Int],
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        var buildErrors = 0
        events.send(.mutantRunsStarted)

        for index in indices {
            let job = jobs[index]
            try Task.checkCancellation()
            // A `muter.xctestrun` that couldn't be written still switches on the mutant before this one, whose
            // verdict an xcodebuild run would record for this one.
            do {
                try await ioDelegate.switchOn(
                    schemata: job.schema,
                    for: state.projectXCTestRun,
                    at: state.mutatedProjectDirectoryURL
                )
            } catch {
                throw MuterError.mutationTestingAborted(
                    reason: .mutantNotSwitchedOn(id: job.schema.id, description: error.localizedDescription)
                )
            }

            let launched = instant()
            let run = await ioDelegate.runTestSuite(
                withSchemata: job.schema,
                using: configuration,
                savingResultsIntoFileNamed: testOutput(
                    named: logFileName(forJobAt: index, job),
                    state: state
                )
            )
            try Self.throwIfCancelled(run)

            try record(
                FinishedRun(index: index, worker: 0, run: run, seconds: seconds(since: launched)),
                of: job,
                using: state,
                configuration: configuration,
                session: session,
                buildErrors: &buildErrors
            )
        }
    }

    /// Tests the jobs at `indices`, started in their order, on `workers` test processes at once, never more than
    /// `indices`, each in its own clone of the mutated project:
    /// `swift test` locks the package's build directory, so two runs can't share one. Every mutant is
    /// switched on per run: under `swift test` by the worker's active-mutant file, written just before the run
    /// (see `MutationTestingDelegate.testProcess`), so the clones' code never needs rewriting. Outcomes are
    /// recorded, and their events sent, as they finish. The timeouts are then tested again, on fewer workers
    /// (`rerunTimeouts`). The clones are kept in `session`, and
    /// `run(with:)` removes them once the end line is written. Once mutation testing is cancelled, no clone
    /// is made, no mutant starts, and none that returns is recorded.
    func testMutationsInParallel(
        _ jobs: [MutantJob],
        _ indices: [Int],
        workers: Int,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        // A clone costs a copy and about one baseline build, which a stopped run would only throw away.
        try Task.checkCancellation()
        let clones: [URL]
        do {
            clones = try await makeWorkerDirectories(state.mutatedProjectDirectoryURL, workers - 1)
        } catch {
            // Stopping the run kills a `cp` under way, which then fails.
            try Task.checkCancellation()
            throw error
        }
        session.clones = clones
        try await buildWorkerDirectories(clones, using: state)
        let directories = [state.mutatedProjectDirectoryURL] + clones

        var buildErrors = 0
        var timeouts: [Int] = []
        events.send(.mutantRunsStarted)

        try await runPool(
            indices,
            of: jobs,
            on: directories,
            using: configuration,
            outputNamed: { testOutput(named: logFileName(forJobAt: $0, $1), state: state) },
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
            timeouts.sorted(), of: jobs, on: directories, using: state, configuration: configuration, session: session
        )
    }

    /// Tests the jobs at `indices` again, whose runs timed out, in job order, a quarter of `directories`' workers at
    /// once, at least one, never more than `indices`: with every worker's tests competing for the same cores, a slow
    /// test can pass the limit that it keeps to under less load. The limit is `configuration`'s, the first runs', so a
    /// mutant that loops forever times out again. Each run's line follows its first run's, which it replaces, and its
    /// events don't count in the progress, which counted the first run (`recordRerun`).
    func rerunTimeouts(
        _ indices: [Int],
        of jobs: [MutantJob],
        on directories: [URL],
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws {
        guard !indices.isEmpty else { return }
        try Task.checkCancellation()
        let reruns = TimeoutReruns(
            count: indices.count,
            workers: min(max(directories.count / 4, 1), indices.count),
            limitSeconds: configuration.testSuiteTimeout
        )
        events.send(.timeoutRerunsStarted(reruns))
        var tally = TimeoutRerunTally(reruns)
        try await runPool(
            indices,
            of: jobs,
            on: Array(directories.prefix(reruns.workers)),
            using: configuration,
            outputNamed: { testOutput(named: logFileName(forRerunOfJobAt: $0, $1), state: state) },
            recording: { finished in
                recordRerun(
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

    /// Runs the jobs at `indices`, started in their order, one at a time in each of `directories`, and hands each run
    /// to `record` as it finishes; the worker that finished it then starts the next job. Each run writes its output to
    /// the file `outputName` names for its job while it runs. Once mutation testing is cancelled, no job starts, and
    /// no run that returns is handed on.
    func runPool(
        _ indices: [Int],
        of jobs: [MutantJob],
        on directories: [URL],
        using configuration: MuterConfiguration,
        outputNamed outputName: (_ index: Int, _ job: MutantJob) -> String,
        recording record: (FinishedRun) throws -> Void
    ) async throws {
        // The worker job loop and its inline cancellation handling genuinely span >30 lines; pulling the body
        // into a helper would split apart a tight loop-and-catch, so the length is disabled for this closure.
        // swiftlint:disable:next closure_body_length
        try await withThrowingTaskGroup(of: FinishedRun.self) { group in
            // The position in `indices` of the next job to start.
            var next = 0
            // Throws once mutation testing is cancelled, rather than skip the job: with no run under way, the
            // loop below would end as if every mutant had been tested.
            func start(_ index: Int, worker: Int) throws {
                let job = jobs[index]
                let directory = directories[worker]
                let fileName = outputName(index, job)
                // A worker's task is given the values and the two dependencies it uses, not the step.
                let started = group.addTaskUnlessCancelled { [ioDelegate, instant] in
                    let launched = instant()
                    let run = await ioDelegate.runTestSuite(
                        withSchemata: job.schema,
                        using: configuration,
                        savingResultsIntoFileNamed: fileName,
                        workingDirectory: directory
                    )
                    return FinishedRun(
                        index: index,
                        worker: worker,
                        run: run,
                        seconds: Self.seconds(from: launched, to: instant())
                    )
                }
                guard started else { throw CancellationError() }
            }

            for worker in directories.indices.prefix(indices.count) {
                try start(indices[next], worker: worker)
                next += 1
            }

            while let finished = try await group.next() {
                // Throwing cancels the other runs, whose cancellation handlers kill their process trees.
                try Self.throwIfCancelled(finished.run)
                try record(finished)
                // The worker that finished takes the next job; the directory is looked up from it.
                if next < indices.count {
                    try start(indices[next], worker: finished.worker)
                    next += 1
                }
            }
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

    /// A run that returns once mutation testing is cancelled may have been ended by SwiftMutator itself, whatever
    /// it says: a process killed before its run's cancellation handler was installed reads as an exit with status
    /// 9, which counts as killed. Such a run is never recorded.
    static func throwIfCancelled(_ run: TestRun) throws {
        if run.ending == .cancelled || Task.isCancelled { throw CancellationError() }
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

    /// How long a mutant's test command takes with no mutant on, once the baseline has built the project, or nil if
    /// that run didn't pass: one that crashed at once says nothing about how long a passing one takes.
    func timeTestRun(
        using configuration: MuterConfiguration,
        state: AnyMutationTestState
    ) async throws -> TimeInterval? {
        let start = instant()
        let (outcome, testLog) = await ioDelegate.runTestsWithoutBuilding(
            using: configuration,
            savingResultsIntoFileNamed: testOutput(named: "timed test run", state: state)
        )
        // Stopping the run kills this run too, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()
        let seconds = outcome == .passed ? seconds(since: start) : nil
        fileManager.keepLog(testLog, named: "timed test run.log", state: state)
        return seconds
    }

    /// The seconds from `start` to now, on the monotonic clock.
    func seconds(since start: DispatchTime) -> TimeInterval {
        Self.seconds(from: start, to: instant())
    }

    /// The seconds from `start` to `end`, two readings of the monotonic clock; none if `end` is the earlier.
    static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        guard end >= start else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
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
        let (outcome, mutationLog) = keep(
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
    ) {
        let (outcome, mutationLog) = keep(
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
    /// failed-test lines unreliable.
    func keep(
        _ finished: FinishedRun,
        of job: MutantJob,
        rerun: MutantResult.Rerun?,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) -> (outcome: MutationTestOutcome.Mutation, log: MutationTestLog) {
        // The failed tests are worked out here, not in `write`'s autoclosure: the outcome needs them without a results
        // file, or after a failed write. One scan of the log serves both.
        let failures = MutantResult.failedTests(
            of: finished.run,
            linesAreReliable: configuration.failedTestLinesAreReliable
        )
        let outcome = Self.outcome(
            finished.run.outcome,
            of: job,
            state: state,
            killingTests: .init(failures, endedBy: finished.run.ending)
        )
        let key = session.keys[finished.index]
        let log = rerun == nil ? MutationTestLog.keptFileName(for: key) : MutationTestLog.rerunFileName(for: key)
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

        let mutationLog = MutationTestLog(
            mutationPoint: outcome.point,
            testLog: finished.run.testLog,
            timePerBuildTestCycle: .none,
            remainingMutationPointsCount: .none,
            keptFileName: log
        )
        return (outcome, mutationLog)
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

    /// Writes the end line of an interrupted session, from the thread that stops SwiftMutator at once, by a second
    /// signal, Ctrl-\ or the grace period: mutation testing never gets to write its own. Static, so that thread is
    /// given the session and the two dependencies it reads, not the step.
    static func endResultsAtOnce(of session: TestingSession, stoppedBy interruption: InterruptionRecord, now: Now) {
        session.end(waitingAtMost: endLineWaitAtOnce) { recorded in
            endLine(
                of: session,
                .interrupted,
                detail: interruption.signal.map(InterruptionRecord.name(of:)),
                testDuration: now().timeIntervalSince(session.startedAt),
                recorded: recorded,
                endedAt: now()
            )
        }
    }

    static func endLine(
        of session: TestingSession,
        _ reason: ResultsEnd.Reason,
        detail: String?,
        testDuration: TimeInterval,
        recorded: Int,
        endedAt: Date
    ) -> ResultsEnd {
        ResultsEnd(
            session: session.number,
            endedAt: endedAt,
            reason: reason,
            detail: detail,
            testDurationSeconds: testDuration,
            recorded: recorded
        )
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
}

extension PerformMutationTesting {
    struct WorkerDirectoryError: Error, CustomStringConvertible {
        let clone: URL
        /// cp's exit status, or nil if it couldn't be started.
        let status: Int32?
        /// The first line cp wrote to standard error, such as why a file couldn't be copied.
        var error: String?

        var description: String {
            let copy = status.map { "cp exited \($0)" } ?? "cp could not be started"
            let why = error.map { ": \($0)" } ?? ""
            return "SwiftMutator could not clone the mutated project to \(clone.path) "
                + "for a parallel worker (\(copy))\(why)."
        }
    }

    /// One clone of `project` per extra worker, next to it as `<name>_worker<n>`. On macOS `cp -c`
    /// clones on APFS, so even a large build directory copies in seconds. Each clone is then built once
    /// before testing (`buildWorkerDirectories`). Every path in it has changed, so that is a full build:
    /// about one baseline build of time, and much of the clone's build directory is rewritten rather
    /// than shared. Its copied Clang module caches record the mutated project's path, so they're
    /// discarded first, as `CopyProjectToTempDirectory` does for the mutated project itself.
    static func cloneMutatedProject(_ project: URL, count: Int) async throws -> [URL] {
        try await cloneMutatedProject(project, count: count, copying: copyProject(_:to:))
    }

    /// `copy` copies the project to one clone. If one fails, the clones made before it are removed, and so is whatever
    /// the failed copy left, rather than staying beside the project until SwiftMutator next starts.
    static func cloneMutatedProject(
        _ project: URL,
        count: Int,
        copying copy: (_ project: URL, _ clone: URL) async throws -> Void
    ) async throws -> [URL] {
        guard count > 0 else { return [] }
        var clones: [URL] = []
        do {
            for index in 1...count {
                let clone = project.deletingLastPathComponent()
                    .appendingPathComponent("\(project.lastPathComponent)_worker\(index)")
                try? FileManager.default.removeItem(at: clone)
                clones.append(clone) // before the copy, which can fail partway through
                try await copy(project, clone)
                discardModuleCaches(in: clone)
            }
            return clones
        } catch {
            removeClones(clones)
            throw error
        }
    }

    private static func copyProject(_ project: URL, to clone: URL) async throws {
        #if os(macOS)
        let copy = await Foundation.Process().runCommand(
            url: "/bin/cp",
            arguments: ["-c", "-R", project.path, clone.path]
        )
        guard let copy, copy.status == 0 else {
            let error = copy?.errors.split(separator: "\n").first.map(String.init)
            throw WorkerDirectoryError(clone: clone, status: copy?.status, error: error)
        }
        #else
        try FileManager.default.copyItem(at: project, to: clone)
        #endif
    }

    static func discardModuleCaches(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        else { return }

        for case let url as URL in enumerator
            where CopyProjectToTempDirectory.moduleCacheDirectoryNames.contains(url.lastPathComponent) {
            // On Darwin, skipping the descendants of anything but a directory skips the next directory.
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes each clone, the active-mutant file and helper link beside it, and its tests' `UserDefaults`, on a
    /// thread of its own: one large clone takes a
    /// fraction of a second or more to remove, and a run that is stopping does this last, when a second signal exits
    /// at once and leaves the rest behind.
    static func removeClones(_ directories: [URL]) {
        DispatchQueue.concurrentPerform(iterations: directories.count) { index in
            let clone = directories[index]
            try? FileManager.default.removeItem(at: MutationTestingDelegate.activeMutantFile(forWorkerIn: clone))
            DirectTestRun.removeOwnDefaults(forWorkerIn: clone)
            try? FileManager.default.removeItem(at: clone)
        }
    }
}
