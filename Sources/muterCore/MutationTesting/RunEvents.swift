import Foundation

/// Something that happens during a run, which `MutationTestObserver` reports as it happens.
enum RunEvent {
    case muterLaunched

    case updateCheckStarted
    /// The newer version available, or nil if there is none or the check failed.
    case updateCheckFinished(newVersion: String?)

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

    /// What a resumed run keeps of its results file and tests again, before anything is tested.
    case resumePlanned(ResumeSummary)
    case mutationTestingStarted
    /// Sent once the mutants start: after the baseline, the timed test run and any worker clones' builds, just before
    /// the first mutant's run.
    case mutantRunsStarted
    case stopAtFirstFailureTurnedOff(reason: String)
    /// Each mutant's tests run through `swift test`, as the bundles can't be run directly (see `DirectTestRun`).
    case testBundlesNotRunDirectly(reason: String)
    case mutationTestingFinished(MutationTestOutcome)
    /// What mutation testing tested before it stopped early, once the baseline passed.
    case mutationTestingEndedEarly(EarlyEnd)

    case newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation)
    case newTestLogAvailable(MutationTestLog)
    case baselineTestFailed(MutationTestLog)
    case resultsFileCreated(path: String)
    /// Why the results file can't be created or written to.
    case resultsFileUnavailable(reason: String)

    case testPlanFileCreated(path: String)

    case muterMutationTestPlanLoaded
}

/// Delivers each of a run's events to whatever observes them, in the order they were added, at once and on the thread
/// that sends the event. So an event has been handled when `send` returns, which the run relies on: the report is
/// written before SwiftMutator exits, and a test's log is in the log folder before its file is removed.
final class RunEvents: @unchecked Sendable { // `observers` and `nextObserver` are behind `lock`
    private let lock = NSLock()
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

    /// Hands `event` to each observer in turn. No lock is held meanwhile, so an observer may send an event of its own.
    func send(_ event: RunEvent) {
        let observing = lock.withLock { observers.map(\.observe) }
        for observe in observing {
            observe(event)
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
