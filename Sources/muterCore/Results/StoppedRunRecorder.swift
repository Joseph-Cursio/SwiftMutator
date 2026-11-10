import Foundation

/// Writes the results file of a run that stops before its first mutant (`ResultsStopped`), once, in the run's log
/// folder, never once the run's results have started. It follows the run's steps, so that a signal, which can come
/// at any moment and from another thread when it stops the run at once, finds where the run was. One per run, which
/// every step shares (`World.stoppedRun`).
final class StoppedRunRecorder: @unchecked Sendable {
    /// How a run stopped before its first mutant.
    enum Stop: Equatable {
        /// A step failed, or ran past its limit, as `reason` says: a failed baseline's kinds, which exit 3.
        case aborted(MutationTestingAbortReason)
        /// `signal` stopped the run.
        case interrupted(signal: Int32)
    }

    private let lock = NSLock()
    private var startedAt: Date?
    private var logDirectory = ""
    private var projectPath = ""
    private var resuming: String?
    private var step: ResultsStopped.Step = .preparing
    private var resultsStarted = false
    private var recorded = false

    /// Starts following a run that started `at`, which keeps its logs in `logDirectory`, none if empty. A run that
    /// tests no mutant, such as one that makes a test plan, isn't followed, and records nothing.
    func start(at date: Date, logDirectory: String, testsMutants: Bool) {
        lock.withLock {
            startedAt = testsMutants ? date : nil
            self.logDirectory = logDirectory
        }
    }

    /// What the run's state now says of its project and the run it resumes.
    func update(projectPath: String, resuming: String?) {
        lock.withLock {
            self.projectPath = projectPath
            self.resuming = resuming
        }
    }

    /// The run is now in `step`.
    func enter(_ step: ResultsStopped.Step) {
        lock.withLock { self.step = step }
    }

    /// The run's results file is about to start, so a stop from now on is recorded there, as an end line, or not at
    /// all. False when a stop was recorded first, at once from a signal's thread: the run then starts no results file.
    func resultsStart() -> Bool {
        lock.withLock {
            guard !recorded else { return false }
            resultsStarted = true
            return true
        }
    }

    /// Writes the record of `stop`, at `date`, unless the results started, it was written already, the run isn't
    /// followed or has no log folder, or `stop` is an abort of a kind that isn't a failed baseline's. The path written,
    /// or nil.
    @discardableResult
    func record(_ stop: Stop, at date: Date) -> String? {
        @Dependency(\.resultsFiles) var resultsFiles: ResultsFileOpening
        @Dependency(\.fileManager) var fileManager: FileSystemManager
        return lock.withLock {
            guard let startedAt, !resultsStarted, !recorded, !logDirectory.isEmpty,
                  let record = record(of: stop, startedAt: startedAt, stoppedAt: date, fileManager: fileManager)
            else { return nil }
            recorded = true
            guard let file = try? resultsFiles.create(in: logDirectory) else { return nil }
            defer { file.close() }
            return file.append(record) ? file.path : nil
        }
    }

    /// What a stop shows: its step, why, its limit, its log's name, and the text whose failed tests the record names.
    private typealias Found = (
        step: ResultsStopped.Step, reason: ResultsStopped.Reason, limit: Double?, log: String?, text: String?
    )

    /// Called with the lock held.
    private func record(
        of stop: Stop,
        startedAt: Date,
        stoppedAt: Date,
        fileManager: FileSystemManager
    ) -> ResultsStopped? {
        let found: Found
        let detail: String?
        switch stop {
        case let .interrupted(signal):
            found = (step, .interrupted, nil, Self.logWhileRunning(of: step, in: logDirectory, fileManager), nil)
            detail = InterruptionRecord.name(of: signal)

        case let .aborted(reason):
            guard reason.exitStatus == .baselineFailed, let what = Self.step(of: reason) else { return nil }
            found = what
            detail = ResultsEnd.detail(for: MuterError.mutationTestingAborted(reason: reason))
        }
        let failed = found.text.map { FailedTestLine.failedTests(inLog: $0) }
        return ResultsStopped(
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            step: found.step,
            reason: found.reason,
            detail: detail,
            limitSeconds: found.limit,
            log: found.log,
            failedTests: failed?.tests,
            failedTestCount: failed?.count,
            projectPath: projectPath,
            logDirectory: logDirectory,
            resuming: resuming
        )
    }

    /// The step a failed baseline's kind of abort stopped in, why, its limit, its log's name, and the log's text, whose
    /// failed tests the record names; nil for any other abort.
    private static func step(of reason: MutationTestingAbortReason) -> Found? {
        let name = { (path: String?) in path.map { ($0 as NSString).lastPathComponent } }
        switch reason {
        case let .baselineTestFailed(log, _):
            return (.baseline, .failed, nil, MutationTestLog.baselineFileName, log)

        case let .workerBaselineTestFailed(worker, _, log):
            return (.workerBaselines, .failed, nil, "baseline run worker \(worker).log", log)

        case let .buildForTestingFailed(_, log):
            return (.buildForTesting, .failed, nil, name(log), nil)

        case let .buildTimeoutReached(step, seconds, output, log):
            let stopped: ResultsStopped.Step = switch step {
            case .buildForTesting: .buildForTesting
            case .baseline: .baseline
            case .workerBaseline: .workerBaselines
            }
            return (stopped, .timedOut, seconds, name(log), output)

        case .tooManyBuildErrors, .mutantNotSwitchedOn, .controlRunNotSwitchedOff, .simulatorUnavailable,
             .noMutantCodeShownRunning, .unknownError:
            return nil
        }
    }

    /// The name, in `logDirectory`, of the log `step` keeps even when stopped, or of the output it was writing, if it
    /// is there: what it printed before the signal came.
    private static func logWhileRunning(
        of step: ResultsStopped.Step,
        in logDirectory: String,
        _ fileManager: FileSystemManager
    ) -> String? {
        let running = PerformMutationTesting.testOutputFolderName + "/"
        let name: String? = switch step {
        case .coverageRun: DiscoverProjectCoverage.logFileName
        case .baseline: running + "baseline run"
        case .directTestRun: running + "direct test run"
        case .timedTestRun: running + "timed test run"
        case .preparing, .buildForTesting, .workerBaselines, .workerCheckRuns: nil
        }
        guard let name, fileManager.fileExists(atPath: (logDirectory as NSString).appendingPathComponent(name)) else {
            return nil
        }
        return name
    }
}
