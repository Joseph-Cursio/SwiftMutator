import Foundation

/// Something that happens during a run, which `MutationTestObserver` reports as it happens.
enum RunEvent {
    case muterLaunched

    case updateCheckStarted
    /// The newer version available, or nil if there is none or the check failed.
    case updateCheckFinished(newVersion: String?)

    /// The keys of the configuration file, by its name, that SwiftMutator doesn't know and so ignores.
    case configurationKeysUnknown([UnknownConfigurationKey], file: String)

    /// What `--since` chose, before anything is copied.
    case changesSelected(ChangeSelection)

    /// The earlier runs' log folders that `keepLogFolders:` removed and left, once some run was beyond the newest it
    /// keeps, before anything is copied.
    case logFoldersPruned(LogFolderPruning)

    case projectCopyStarted
    /// The paths that vanished while the project was being copied, as a build tool's temporary files do.
    case projectCopySkippedVanishedFiles([String])
    case projectCopyFinished(destinationPath: String)
    /// The build phases of the copy's Xcode projects whose SwiftLint was turned off, and those it may still run in.
    case swiftLintPhasesTurnedOff(SwiftLintPhases)

    case projectCoverageDiscoveryStarted
    /// Why coverage couldn't be gathered, or nil when it was.
    case projectCoverageDiscoveryFinished(CoverageFailure?)
    /// The tests that failed in the coverage run, whose coverage was still gathered.
    case projectCoverageTestsFailed(TestsFailedWithCoverage)

    case sourceFileDiscoveryStarted
    /// Why the Swift files a SwiftPM package's targets compile couldn't be listed, so discovery looks in the whole
    /// project.
    case packageSourceFilesUnavailable(reason: String)
    /// Why SwiftMutator can't tell which `#if` branches the build compiles.
    case buildConditionsUnavailable(reason: String)
    /// The `--files-to-mutate` entries that leave no file to mutate.
    case filesToMutateUnmatched([UnmatchedFilesToMutate])
    case sourceFileDiscoveryFinished([FilePath])

    case mutationsDiscoveryStarted
    case mutationsDiscoveryFinished([SchemataMutationMapping])
    /// With `--sample` or `--shard`, in place of `mutationsDiscoveryFinished`: the sample and the shard tested, and
    /// their mutants.
    case mutantsSelected(sample: SampleSelection?, shard: ShardSelection?, mutations: [SchemataMutationMapping])
    /// The mutants discovery found and can't test, as their switches have nowhere to go.
    case mutantsDropped([DroppedMutant])

    /// What a resumed run keeps of its results file and tests again, before anything is tested.
    case resumePlanned(ResumeSummary)
    case mutationTestingStarted
    /// Sent once the mutants start: after the baseline, the timed test run and any worker clones' builds, just before
    /// the first mutant's run.
    case mutantRunsStarted
    /// The mutants under way once none has finished for `Heartbeat.interval`, and again each interval while none does.
    case stillTesting(StillTesting)
    /// How many workers test the mutants, and why fewer than asked for, once the baseline has passed.
    case workersChosen(WorkerChoice)
    case stopAtFirstFailureTurnedOff(reason: String)
    /// Each mutant's tests run through `swift test`, as the bundles can't be run directly (see `DirectTestRun`).
    case testBundlesNotRunDirectly(reason: String)
    /// The timed test run, with no mutant on, ran for its limit, `seconds`, and was stopped, so the mutants' time limit
    /// comes from the baseline (`followingRunLimit`). `log` is where its log is kept, if it is.
    case timedTestRunStopped(seconds: TimeInterval, log: String?)
    /// The run stopped before its first mutant, and recorded why in the results file at `path` (`ResultsStopped`).
    case stoppedRunRecorded(path: String)
    /// More than one worker tests mutants through `swift test`, so their tests share `UserDefaults.standard` (#92).
    case workersShareUserDefaults
    /// A direct run of the tests, with no mutant on, changed `path` in the project, so workers keep a clone each.
    case testBundlesWroteInTheProject(path: String)
    /// The build failed on `count` mutants' code, which `CompileRecovery` took out, before it builds again. Only a
    /// build that passes shows they were at fault: the project itself may not compile.
    case buildingAgainWithoutMutants(count: Int)
    /// The build failed where a result builder can't take the `if` of `count` mutants' switches, which
    /// `CompileRecovery` put in a closure called on the spot, before it builds again.
    case buildingAgainWithSwitchesInAClosure(count: Int)
    /// `CompileRecovery` has taken out mutants after `afterBuilds` failed builds, its most, and the next failed too, so
    /// its errors may still be mutants'. The failure then stops the run.
    case stoppedTakingOutMutants(afterBuilds: Int)
    /// The mutants the run won't test, as they don't compile, once the build without them has passed and their results
    /// are written.
    case mutantsLeftOutOfTheBuild(MutantsLeftOut)
    /// A control run, with no mutant on, among the mutants, once its line is written. Never counted in the progress.
    case controlRunFinished(ControlRunFinished)
    /// None of `runs` mutants' runs showed whether their blocks ran, so their verdicts stand as the runs had them.
    case activationNotShown(runs: Int)
    /// `count` runs that failed or timed out without showing their mutants' blocks ran are about to be tested again.
    case unprovenRunsRerunStarted(count: Int)
    /// What one of them came to, and whether that isn't what its first run came to.
    case unprovenRunRerun(MutationTestOutcome.Mutation, changed: Bool)
    case unprovenRunsRerunFinished(UnprovenRunTally)
    /// The tests didn't pass alone with no mutant on, so no kill is tested again alone: `log` holds that run.
    case suspectKillRerunsSkipped(log: String?)
    /// Kills only suspect tests failed for are about to be tested again alone.
    case suspectKillRerunsStarted(SuspectKillReruns)
    /// What one of them came to, and whether that isn't what its first run came to.
    case suspectKillRerun(MutationTestOutcome.Mutation, changed: Bool)
    case suspectKillRerunsFinished(SuspectKillRerunTally)
    /// Once every mutant is tested on more than one worker, the timeouts that are tested again, on fewer.
    case timeoutRerunsStarted(TimeoutReruns)
    /// A timeout tested again, once its line is written. Never counted in the progress, which counted its first run.
    case timeoutRerunFinished(TimeoutRerun)
    /// What the timeouts tested again came to, once every one is.
    case timeoutRerunsFinished(TimeoutRerunTally)
    /// Once every mutant is tested, the kills whose recorded tests include no property test, which the property tests
    /// alone test again (`PropertyReruns`).
    case propertyRerunsStarted(PropertyReruns)
    /// What those runs came to, once every one is.
    case propertyRerunsFinished(PropertyRerunTally)
    /// Why no kill is tested again with the property tests alone, though some would be: their run with no mutant on
    /// didn't pass, or ran no test. With the name of that run's kept log, if kept.
    case propertyRerunsSkipped(reason: String, log: String?)
    /// A mutant's xcodebuild run that the simulator failed to launch, which ran again in its place, once the second
    /// run's result is written, just before its outcome is sent. Never counted in the progress, which counts the second
    /// run.
    case runRepeatedAfterLaunchFailure(RepeatedRun)
    /// An xcodebuild baseline that the simulator failed to launch, with the line that showed it and its log, once the
    /// baseline has run again in its place, before that run's outcome is known to anyone.
    case baselineRepeatedAfterLaunchFailure(line: String, log: MutationTestLog)
    /// A run of one mutant (`--mutant`), once its line is written, which `mutationTestingFinished` then prints in
    /// place of the report.
    case oneMutantTested(OneMutantRun)
    case mutationTestingFinished(MutationTestOutcome)
    /// What mutation testing tested before it stopped early, once the baseline passed.
    case mutationTestingEndedEarly(EarlyEnd)

    case newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation)
    case newTestLogAvailable(MutationTestLog)
    case resultsFileCreated(path: String)
    /// Why the results file can't be created or written to.
    case resultsFileUnavailable(reason: String)

    case testPlanFileCreated(TestPlanCreated)

    case muterMutationTestPlanLoaded
    /// The plan doesn't record the project's files, as a plan in format 0 doesn't, so the project isn't checked
    /// against it.
    case testPlanSourcesUnchecked
    /// Project files the plan doesn't mutate that changed since it was made, whether or not `--plan-ignoring` matches
    /// them: the copy holds them as they were.
    case testPlanSourcesDiffer([ProjectTree.FileChange])
    /// Files with the plan's other mutants, which `--mutant` leaves out of the run, that changed since it was made: a
    /// run that tests those mutants refuses the plan unless `--plan-ignoring` lets the changes through.
    case testPlanUntestedFilesChanged([ProjectTree.FileChange])
    /// Files the plan mutates that changed since it was made, which `--plan-ignoring` let through.
    case testPlanChangesWaived([String])
    /// Files with mutants that the plan's copy holds otherwise than `mutate-without-running` left them, as a fix by
    /// hand does, by their paths relative to the copy; they are tested as they are.
    case testPlanCopyEdited([String])
    /// Dependency resolution files of the plan's copy, which the project the plan was made from didn't have, that
    /// changed since a resumed run's last session, as the copy's own build writes them: they don't refuse the resume.
    case testPlanCopyResolutionChanged([ProjectTree.FileChange])
}

/// Delivers each of a run's events to whatever observes them, in the order they were added, at once and on the thread
/// that sends the event. So an event has been handled when `send` returns, which the run relies on: the report is
/// written before SwiftMutator exits. Events go out one at a time, whichever threads send them, so observers such as
/// `Logger` need no lock of their own.
final class RunEvents: @unchecked Sendable { // `observers` and `nextObserver` are behind `lock`
    private let lock = NSLock()
    /// Held while an event is handed out, so that another thread's event waits for it. Recursive, so that an observer
    /// may send an event of its own.
    private let delivering = NSRecursiveLock()
    private var observers: [(key: Int, observe: (RunEvent) -> Void)] = []
    private var nextObserver = 0

    /// Calls `observe` with each event sent from now on, until the returned subscription is cancelled.
    func observe(_ observe: @escaping (RunEvent) -> Void) -> Subscription {
        let key = lock.withLock {
            nextObserver += 1
            observers.append((nextObserver, observe))
            return nextObserver
        }
        return Subscription { [weak self] in self?.stopObserving(key) }
    }

    /// Hands `event` to each observer in turn, once no other thread is handing one out. `lock` isn't held meanwhile, so
    /// an observer may stop observing.
    func send(_ event: RunEvent) {
        delivering.withLock {
            let observing = lock.withLock { observers.map(\.observe) }
            for observe in observing {
                observe(event)
            }
        }
    }

    private func stopObserving(_ key: Int) {
        lock.withLock { observers.removeAll { $0.key == key } }
    }

    /// An observer's registration. Cancelling it, from any thread, or letting it go, stops the observer's events.
    final class Subscription: @unchecked Sendable { // `isCancelled` is behind `lock`
        private let lock = NSLock()
        private let cancelling: @Sendable () -> Void
        private var isCancelled = false

        fileprivate init(cancelling: @escaping @Sendable () -> Void) {
            self.cancelling = cancelling
        }

        func cancel() {
            let cancelsNow = lock.withLock {
                defer { isCancelled = true }
                return !isCancelled
            }
            if cancelsNow { cancelling() }
        }

        deinit {
            cancel()
        }
    }
}
