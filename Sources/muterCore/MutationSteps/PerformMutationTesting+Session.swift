import Foundation
import SwiftSyntax

/// A session's steps before its mutants' runs: the baseline, the direct runs, the workers and the timed test run.
extension PerformMutationTesting {
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
        // A simulator tests only what is in the build, which `BuildForTesting` has already built.
        let simulators = try await simulatorWorkerSetup.make(
            for: plan.leavingOut { state.mutantsLeftOut[jobs[$0].schema.id] != nil }.toRun.count,
            state: state
        )
        // The boot is given the dependency it uses, not the step.
        let booting = workerSimulators
        async let booted = SimulatorWorkerSetup.boot(simulators, on: booting)

        stoppedRun.enter(.baseline)
        let (testSuiteOutcome, testLog, timePerBuildTestCycle, leftOut) = try await baselineLeavingOutMutants(
            state: state
        )

        // A failing baseline's log, which `baseline` kept, is exactly what the user needs on disk.
        guard testSuiteOutcome == .passed else {
            throw MuterError.mutationTestingAborted(
                reason: .baselineTestFailed(
                    log: testLog,
                    mutatedFilePaths: state.mutationMapping.map(\.filePath)
                )
            )
        }

        // The mutants that don't compile have a result, written below, so they count in the header and a resume's plan,
        // and aren't in anything that tests them.
        let testing = plan.leavingOut { leftOut[jobs[$0].schema.id] != nil }

        // One mutant's run shows every test it fails, not only the first.
        var muterConfiguration = state.selectedMutant == nil
            ? state.muterConfiguration
            : state.muterConfiguration.withoutStoppingAtFirstFailure()
        // A passing run can't show a failed test or a crash, so these tests print text shaped like one. Under a
        // mutant it could stop the run, or count a timed-out run killed, although every test passed, so such lines
        // don't count for this run, nor do the tests they show failing count among a mutant's failed tests. Checked
        // whether or not runs stop at their first failed test, but worth a notice only if they do, sent before the
        // baseline's log, which starts the progress bar or lines. Worker clones' baselines keep the configuration as
        // it was: a baseline is never stopped at a failed test, and has no mutant's time limit, only `buildTimeout`'s.
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
        // Before the workers: a direct run that wrote nothing in the project lets them share one build.
        stoppedRun.enter(.directTestRun)
        let direct = try await directRuns(
            of: testing, muterConfiguration, baselineLog: testLog, baselineSeconds: timePerBuildTestCycle, state: state
        )
        stoppedRun.enter(muterConfiguration.buildSystem == .xcodebuild ? .workerCheckRuns : .workerBaselines)
        let pool = try await workers(
            testing: testing,
            on: checked,
            with: direct.configuration,
            mayShareBuild: direct.wroteNothing,
            state: state,
            session: session
        )
        muterConfiguration = pool.configuration
        let workers = pool.count
        stoppedRun.enter(.timedTestRun)
        let (configuration, testRunSeconds) = try await mutantRuns(
            muterConfiguration,
            on: pool,
            testing: testing,
            directRunSeconds: direct.seconds,
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
        keepLeftOut(leftOut, testing: plan, leaving: testing.toRun.count, of: jobs, in: session, state: state)
        // A reuse with nothing left to test ran the baseline only to check the changed project, as a run whose mutants
        // don't compile has only built it, so it sends no log to start the progress bar or lines. `baseline` kept its
        // log.
        guard !testing.toRun.isEmpty else { return }

        // The first estimate of the time left: every mutant to test, spread over the workers.
        events.send(
            .newTestLogAvailable(MutationTestLog(
                mutationPoint: .none,
                testLog: testLog,
                timePerBuildTestCycle: timePerBuildTestCycle,
                remainingMutationPointsCount: testing.toRun.count,
                workers: workers,
                testRunSeconds: testRunSeconds
            ))
        )

        let tasks = Self.tasks(testing.toRun, controlRunEvery: Self.controlRunEvery(state, configuration))
        let context = RunContext(state: state, configuration: configuration, session: session)
        if workers > 1 {
            try await testMutationsInParallel(jobs, tasks, workers: workers, in: context)
        } else {
            try await testMutations(jobs, tasks, in: context)
        }
    }

    /// The configuration `pool` tests `plan`'s mutants with, from `configuration`, the effective one: on the first
    /// xcodebuild worker, and with the default time limit unless one is configured, from the baseline's
    /// `baselineSeconds`, `directRunSeconds` or a timed test run. Also the timed test run's seconds, if one passed.
    private func mutantRuns(
        _ configuration: MuterConfiguration,
        on pool: SimulatorWorkerSetup.Workers,
        testing plan: ResumePlan,
        directRunSeconds: TimeInterval?,
        baselineSeconds: TimeInterval,
        state: AnyMutationTestState
    ) async throws -> (configuration: MuterConfiguration, testRunSeconds: TimeInterval?) {
        var configuration = configuration
        var testRunSeconds: TimeInterval?
        // A reuse with nothing left to test ran the baseline only to see that the changed tests pass. One mutant's run
        // saves no more than either costs, so its time limit is the configured one, or the baseline's default.
        let timesATestRun = !plan.toRun.isEmpty && state.selectedMutant == nil
        if configuration.buildSystem == .swift, timesATestRun {
            // The run that checked the direct runs is a mutant's run with no mutant on, which needn't run again.
            if configuration.testSuiteTimeout == nil {
                testRunSeconds = directRunSeconds
            }
            // Only a direct run's tests have `UserDefaults` of their own. Sent on Linux too, which never runs directly,
            // and which keeps the shared domain in `~/.config/<package>-test-runner.plist`.
            if pool.count > 1, configuration.directTestRun == nil {
                events.send(.workersShareUserDefaults)
            }
        }
        configuration = Self.onFirstXcodeWorker(configuration, state, pool.xcodeWorkers.first)
        // An xcodebuild run's is on the first worker, as its mutants run, after any check runs, which paid for each
        // simulator's first install and launch.
        if testRunSeconds == nil, timesATestRun, configuration.testSuiteTimeout == nil,
           configuration.buildSystem != .unknown {
            let timeLimit = Self.followingRunLimit(
                buildTimeout: configuration.buildTimeout,
                baselineSeconds: baselineSeconds,
                checkRunSeconds: pool.checkRunSeconds
            )
            testRunSeconds = try await timedTestRun.seconds(
                using: configuration,
                timeLimit: timeLimit,
                state: state,
                testOutput: testOutput(named: "timed test run", state: state)
            )
        }
        let limit = Self.defaultTimeout(testRunSeconds: testRunSeconds, baselineSeconds: baselineSeconds, on: pool)
        return (configuration.withDefaultTestSuiteTimeout(limit), testRunSeconds)
    }

    /// The workers that test `plan`'s mutants, with `configuration`, the effective one, said, with why fewer than asked
    /// for, once they are known. A clone costs a copy and about a baseline build, and a simulator a boot, so there are
    /// never more workers than mutants to test. An xcodebuild run's `simulators` are checked first, which can fall back
    /// to one worker on the test command's destination, and can make failed-test lines unreliable
    /// (`SimulatorWorkerSetup`). A lone worker's said to test on a simulator of its own only when it does. A SwiftPM
    /// run's clones are then made and built (`clonesMade`), here rather than later, as without them a default run tests
    /// on one worker, which its time limit and its results file's header must say. A stop meanwhile throws a
    /// CancellationError, with nothing yet to report. With `mayShareBuild`, a SwiftPM run needs no clones: its workers
    /// beyond the first are only names, in `session` as clones are, and test from the mutated project's build.
    private func workers(
        testing plan: ResumePlan,
        on simulators: SimulatorWorkerSetup.Simulators,
        with configuration: MuterConfiguration,
        mayShareBuild: Bool,
        state: AnyMutationTestState,
        session: TestingSession
    ) async throws -> SimulatorWorkerSetup.Workers {
        let workers = try await simulatorWorkerSetup.workers(
            configuration.workerCount(testing: plan.toRun.count, sharingBuild: mayShareBuild),
            on: simulators,
            configuration: configuration,
            state: state,
            session: session
        ) { testOutput(named: $0, state: state) }
        let sharesBuild = workers.count > 1 && mayShareBuild
        if !plan.toRun.isEmpty {
            let choice = WorkerChoice(
                configuration,
                used: workers.count,
                mutantsToTest: plan.toRun.count,
                unsupportedReason: workers.unavailable,
                ownSimulator: !workers.xcodeWorkers.isEmpty,
                sharesBuild: sharesBuild
            )
            events.send(.workersChosen(choice))
        }
        guard configuration.buildSystem == .swift, workers.count > 1 else { return workers }
        if sharesBuild, let direct = configuration.directTestRun {
            try Task.checkCancellation()
            let project = state.mutatedProjectDirectoryURL
            session.clones = (1..<workers.count).map { MutatedProjectNames.clone($0, of: project) }
            return SimulatorWorkerSetup.Workers(
                count: workers.count,
                unavailable: nil,
                configuration: configuration.withDirectTestRun(direct.sharingBuild(of: project)),
                xcodeWorkers: []
            )
        }
        return try await clonesMade(
            for: workers, testing: plan, configuration: configuration, state: state, session: session
        )
    }

    /// `configuration`, for an xcodebuild project, with its mutants' runs on the first xcodebuild worker, as one worker
    /// alone has it: on `worker`'s simulator when the run made one for its lone worker
    /// (`SimulatorWorkerSetup.Workers.xcodeWorkers`), else on the test command's destination. Either way they test
    /// from `muter.xctestrun`, and keep their derived data beside the mutated project rather than in
    /// `~/Library/Developer/Xcode/DerivedData`, where every run made a new folder. They turn test diagnostics off if
    /// the test command takes the option.
    private static func onFirstXcodeWorker(
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

    /// Deletes the worker simulators an earlier xcodebuild run of the project left, stopped at once, killed or crashed,
    /// with those of any run that has ended. Booted, each holds memory, which the baseline could use. Under the mutated
    /// project's lock, so no run of this project is under way.
    private func sweepLeftoverSimulators(_ state: AnyMutationTestState) async {
        guard state.muterConfiguration.buildSystem == .xcodebuild else { return }
        await workerSimulators.sweep(state.mutatedProjectDirectoryURL)
    }
}
