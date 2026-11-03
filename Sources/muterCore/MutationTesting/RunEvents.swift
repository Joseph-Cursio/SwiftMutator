import Foundation

/// Something that happens during a run, which `MutationTestObserver` reports as it happens.
enum RunEvent {
    case muterLaunched

    case updateCheckStarted
    /// The newer version available, or nil if there is none or the check failed.
    case updateCheckFinished(newVersion: String?)

    /// What `--since` chose, before anything is copied.
    case changesSelected(ChangeSelection)

    case projectCopyStarted
    /// The paths that vanished while the project was being copied, as a build tool's temporary files do.
    case projectCopySkippedVanishedFiles([String])
    case projectCopyFinished(destinationPath: String)

    case projectCoverageDiscoveryStarted
    /// Why coverage couldn't be gathered, or nil when it was.
    case projectCoverageDiscoveryFinished(CoverageFailure?)
    /// The tests that failed in the coverage run, whose coverage was still gathered.
    case projectCoverageTestsFailed(TestsFailedWithCoverage)

    case sourceFileDiscoveryStarted
    /// Why the Swift files a SwiftPM package's targets compile couldn't be listed, so discovery looks in the whole
    /// project.
    case packageSourceFilesUnavailable(reason: String)
    case sourceFileDiscoveryFinished([FilePath])

    case mutationsDiscoveryStarted
    case mutationsDiscoveryFinished([SchemataMutationMapping])
    /// With `--sample` or `--shard`, in place of `mutationsDiscoveryFinished`: the sample and the shard tested, and
    /// their mutants.
    case mutantsSelected(sample: SampleSelection?, shard: ShardSelection?, mutations: [SchemataMutationMapping])

    /// What a resumed run keeps of its results file and tests again, before anything is tested.
    case resumePlanned(ResumeSummary)
    case mutationTestingStarted
    /// Sent once the mutants start: after the baseline, the timed test run and any worker clones' builds, just before
    /// the first mutant's run.
    case mutantRunsStarted
    /// How many workers test the mutants, and why fewer than asked for, once the baseline has passed.
    case workersChosen(WorkerChoice)
    case stopAtFirstFailureTurnedOff(reason: String)
    /// Each mutant's tests run through `swift test`, as the bundles can't be run directly (see `DirectTestRun`).
    case testBundlesNotRunDirectly(reason: String)
    /// Once every mutant is tested on more than one worker, the timeouts that are tested again, on fewer.
    case timeoutRerunsStarted(TimeoutReruns)
    /// A timeout tested again, once its line is written. Never counted in the progress, which counted its first run.
    case timeoutRerunFinished(TimeoutRerun)
    /// What the timeouts tested again came to, once every one is.
    case timeoutRerunsFinished(TimeoutRerunTally)
    /// A run of one mutant (`--mutant`), once its line is written, which `mutationTestingFinished` then prints in
    /// place of the report.
    case oneMutantTested(OneMutantRun)
    case mutationTestingFinished(MutationTestOutcome)
    /// What mutation testing tested before it stopped early, once the baseline passed.
    case mutationTestingEndedEarly(EarlyEnd)

    case newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation)
    case newTestLogAvailable(MutationTestLog)
    case baselineTestFailed(MutationTestLog)
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
/// written before SwiftMutator exits, and a test's log is in the log folder before its file is removed. Events go out
/// one at a time, whichever threads send them, so observers such as `Logger` need no lock of their own.
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
