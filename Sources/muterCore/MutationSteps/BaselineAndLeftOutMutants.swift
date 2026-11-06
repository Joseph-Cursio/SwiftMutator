import Foundation

/// The baseline, which builds the project, without any mutant that doesn't compile (`CompileRecovery`), and the results
/// of those mutants.
extension PerformMutationTesting {
    /// The baseline, with any mutant that fails its build taken out of the code, until it no longer fails on one
    /// (`CompileRecovery`): its outcome and log, the seconds it took, and those mutants, with any `BuildForTesting`
    /// took out. Only the last run is timed: it is what a mutant's run costs, with failed builds' costs behind it.
    /// xcodebuild's build came first, in `BuildForTesting`: a rewrite here would leave the tests it copied out of date.
    func baselineLeavingOutMutants(
        state: AnyMutationTestState
    ) async throws -> (
        outcome: TestSuiteOutcome,
        testLog: String,
        seconds: TimeInterval,
        leftOut: [String: LeftOutMutant]
    ) {
        var recovery = state.muterConfiguration.buildSystem == .xcodebuild ? nil : CompileRecovery(of: state)
        var started = Date()
        var (outcome, testLog) = try await baseline(state: state)
        while outcome != .passed, var trying = recovery {
            let buildLog = MutationTestLog.failedBuildFileName(trying.failedBuilds + 1)
            guard let count = try await trying.takeOutMutants(
                failing: testLog,
                keptAs: buildLog,
                testsMayHaveRun: true
            ) else { break }
            recovery = trying
            fileManager.keepLog(testLog, named: buildLog, state: state)
            events.send(.buildingAgainWithoutMutants(count: count))
            started = Date()
            (outcome, testLog) = try await baseline(state: state)
        }
        if outcome != .passed, recovery?.stopsAtTheMostBuilds == true {
            events.send(.stoppedTakingOutMutants(afterBuilds: CompileRecovery.maximumBuilds))
        }
        let seconds = DateInterval(start: started, end: Date()).duration
        return (outcome, testLog, seconds, state.mutantsLeftOut.merging(recovery?.leftOut ?? [:]) { first, _ in first })
    }

    /// The baseline run's outcome and log, which is kept, whatever it comes to. A baseline the simulator failed to
    /// launch says nothing about the tests either, so it runs once more, as a mutant's run does
    /// (`SimulatorTrouble.launch`), and the first run's log is kept and sent, whatever the second comes to. The caller
    /// times both runs: the first paid for the build. A stop throws, and leaves the output where it ran.
    private func baseline(state: AnyMutationTestState) async throws -> (outcome: TestSuiteOutcome, testLog: String) {
        let output = testOutput(named: "baseline run", state: state)
        let (baseline, launchFailure) = await TestRun.launchedOnceMore(ifNeededWith: state.muterConfiguration) {
            let (outcome, testLog) = await ioDelegate.benchmarkTests(
                using: state.muterConfiguration,
                savingResultsIntoFileNamed: output
            )
            return TestRun(outcome: outcome, testLog: testLog)
        }
        // Stopping the run kills the baseline run, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()
        // Now, so that a stop before the mutants' runs, or a failed baseline's abort, still has it.
        fileManager.keepLog(
            baseline.testLog, writtenTo: output, by: ioDelegate, named: MutationTestLog.baselineFileName, state: state
        )
        if let launchFailure {
            let keptFileName = MutationTestLog.launchFailedFileName(for: MutationTestLog.baselineFileName)
            fileManager.keepLog(launchFailure.testLog, named: keptFileName, state: state)
            let log = MutationTestLog(
                mutationPoint: .none,
                testLog: launchFailure.testLog,
                timePerBuildTestCycle: .none,
                remainingMutationPointsCount: .none,
                keptFileName: keptFileName
            )
            events.send(.baselineRepeatedAfterLaunchFailure(line: launchFailure.line, log: log))
        }
        return (baseline.outcome, baseline.testLog)
    }

    /// Records as a build error each mutant `plan` was to test that `leftOut` holds, as it wasn't in the build, with
    /// its log, which says why, and says which they were, sending what a tested mutant's result sends but its test log:
    /// no progress bar or lines count it, as they don't a kept result. So a mutant with a kept result keeps it, and has
    /// one result. Never counts toward the build errors in a row that stop mutation testing, which say a mutant's run
    /// failed to build.
    func keepLeftOut(
        _ leftOut: [String: LeftOutMutant],
        testing plan: ResumePlan,
        leaving toTest: Int,
        of jobs: [MutantJob],
        in session: TestingSession,
        state: AnyMutationTestState
    ) {
        session.notInTheBuild = Set(jobs.indices.filter { leftOut[jobs[$0].schema.id] != nil })
        var mutants: [MutantsLeftOut.Mutant] = []
        for index in plan.toRun {
            let job = jobs[index]
            guard let mutant = leftOut[job.schema.id] else { continue }
            let key = session.keys[index]
            let logName = MutationTestLog.keptFileName(for: key)
            var line = MutantResult.leftOutOfTheBuild(
                key: key,
                schema: job.schema,
                session: session.number,
                finishedAt: now(),
                log: logName,
                fileSHA256: state.projectTree?.files[key.path]
            )
            line.leftOutWithOthers = mutant.blame == .itself ? nil : true
            write(line, in: session, isAMutant: true)
            var outcome = Self.outcome(
                .buildError, of: job, state: state, killingTests: nil, key: key, durationSeconds: 0
            )
            outcome.leftOutWithOthers = mutant.blame != .itself
            session.outcomes[index] = outcome
            session.leftOut += 1
            let logPath = fileManager.keepLog(mutant.log, named: logName, state: state)
            events.send(.newMutationTestOutcomeAvailable(outcome))
            mutants.append(MutantsLeftOut.Mutant(key: key, change: job.schema.snapshot.description, mutant: mutant))
            if state.selectedMutant != nil {
                events.send(
                    .oneMutantTested(OneMutantRun(
                        key: key,
                        switchID: job.schema.id,
                        snapshot: job.schema.snapshot,
                        change: change(of: job.schema, key: key, in: outcome, state: state),
                        outcome: .buildError,
                        killingTests: nil,
                        seconds: 0,
                        timeoutSeconds: nil,
                        testLog: mutant.log,
                        logPath: logPath,
                        mutatedProject: state.mutatedProjectDirectoryURL.path,
                        buildSystem: state.muterConfiguration.buildSystem,
                        testCommand: [state.muterConfiguration.testCommandExecutable]
                            + state.muterConfiguration.testCommandArguments,
                        leftOutOfTheBuild: true
                    ))
                )
            }
        }
        // One mutant's run says it in its verdict.
        if !mutants.isEmpty, state.selectedMutant == nil {
            events.send(.mutantsLeftOutOfTheBuild(MutantsLeftOut(mutants: mutants, toTest: toTest)))
        }
    }

    /// The outcome of `job`'s mutant, which `testSuiteOutcome` says, given whether its block ran, with the tests that
    /// killed it, as the report shows it.
    static func outcome(
        _ testSuiteOutcome: TestSuiteOutcome,
        of job: MutantJob,
        state: AnyMutationTestState,
        killingTests: MutationTestOutcome.KillingTests?,
        reusedFrom: ReusedFrom? = nil,
        key: MutantKey,
        durationSeconds: Double,
        activated: Bool? = nil
    ) -> MutationTestOutcome.Mutation {
        var mutation = MutationTestOutcome.Mutation(
            testSuiteOutcome: testSuiteOutcome.judged(activated: activated),
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
        mutation.activated = activated
        return mutation
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
}
