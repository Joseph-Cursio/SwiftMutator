import Foundation
import SwiftSyntax

struct PerformMutationTesting: MutationStep {
    // Only `interruption` is private: the step's extensions in other files, such as
    // PerformMutationTesting+ControlRuns.swift, use the others.
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
    var resultsFiles: ResultsFileOpening
    @Dependency(\.provenance)
    var provenance: ProvenanceProbe
    @Dependency(\.interruption)
    private var interruption: InterruptionRecord
    @Dependency(\.stoppedRun)
    var stoppedRun: StoppedRunRecorder
    @Dependency(\.directTestRun)
    var directTestRun: DirectTestRunProbe
    @Dependency(\.workerSimulators)
    var workerSimulators: WorkerSimulating
    @Dependency(\.sleep)
    var sleep: Sleep
    @Dependency(\.projectFiles)
    var projectFiles: @Sendable (URL) -> ProjectFiles?

    let simulatorWorkerSetup = SimulatorWorkerSetup()
    let timedTestRun = TimedTestRun()

    let buildErrorsThreshold: Int = 5

    /// The folder in the run's log folder that each test run writes its output to while it runs. Never the mutated
    /// project or a clone, where a test that lists the package's files, or asks git for untracked ones, would see it.
    /// Once a run is recorded, its file is moved to the name the log folder keeps its log under, or removed, so only
    /// the output of runs that weren't recorded stays: those a stop cut short, and those that finished but weren't
    /// recorded before a stop or an abort.
    static let testOutputFolderName = "running"

    /// Clones the mutated project for each extra parallel worker, and removes the clones afterwards.
    /// Injected so tests don't touch the disk.
    let makeWorkerDirectories: (_ mutatedProject: URL, _ count: Int) async throws -> [URL]
    let removeWorkerDirectories: (_ directories: [URL]) -> Void
    /// The mutants under way, for the line that names them once none has finished for a while.
    let heartbeat = Heartbeat()

    /// What the run that checks direct runs left: the configuration its mutants run with, how long it took, and
    /// whether it wrote nothing in the project.
    struct DirectRuns {
        let configuration: MuterConfiguration
        let seconds: TimeInterval?
        let wroteNothing: Bool
    }

    init(
        makeWorkerDirectories: @escaping (URL, Int) async throws -> [URL] = Self.cloneMutatedProject,
        removeWorkerDirectories: @escaping ([URL]) -> Void = Self.removeClones
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
            startedAt: now(),
            number: (resumed?.lastSession ?? 0) + 1,
            earlierTestDuration: resumed?.recorded.testDuration ?? 0
        )
        // After the end line and anything sent about an early end: removing large clones can take seconds, and a
        // second signal in that time exits at once. A clone left behind is removed when SwiftMutator next runs.
        defer { removeWhatTheRunLeft(in: state, session: session) }
        // A resumed file's lock goes before the clones are removed, as a first session's goes at its end line: also
        // when the baseline failed, which writes nothing to the file.
        defer { resume?.file?.close() }
        // Stopping at once ends SwiftMutator wherever mutation testing is, so the end line is written then: `report`
        // would otherwise take the run for one that is still running, or was killed.
        // Before its results start, a stop at once records it as stopped before its first mutant, which a stop after
        // doesn't.
        interruption.beforeStoppingAtOnce { [interruption, now, stoppedRun] in
            Self.endResultsAtOnce(of: session, stoppedBy: interruption, now: now)
            if let signal = interruption.signal {
                stoppedRun.record(.interrupted(signal: signal), at: now())
            }
        }
        // As the handler's, which this replaced, and first of the defers, before the clean-up above, which can take
        // seconds: a stop at once during it still records a run stopped before its first mutant.
        defer {
            interruption.beforeStoppingAtOnce { [interruption, now, stoppedRun] in
                if let signal = interruption.signal {
                    stoppedRun.record(.interrupted(signal: signal), at: now())
                }
            }
        }

        do {
            try await performMutationTesting(using: state, session: session)
        } catch {
            endEarly(of: session, by: error, state: state)
            throw error
        }

        let thisSession = now().timeIntervalSince(session.startedAt)
        endResults(of: session, .finished, testDuration: thisSession)

        let mutationTestOutcome = Self.mutationTestOutcome(
            of: session,
            state: state,
            testDuration: session.earlierTestDuration + thisSession
        )

        events.send(.mutationTestingFinished(mutationTestOutcome))

        return [.mutationTestOutcomeGenerated(mutationTestOutcome)]
    }

    /// Ends the results of `session`, which `error` stopped, and sends what it tested, if anything.
    private func endEarly(of session: TestingSession, by error: Error, state: AnyMutationTestState) {
        let reason: ResultsEnd.Reason = error is CancellationError ? .interrupted : .aborted
        // The stopping signal tells a CI cancellation (SIGTERM) apart from a Ctrl-C (SIGINT). A cancellation
        // that no signal caused has no detail.
        let detail = reason == .interrupted
            ? interruption.signal.map(InterruptionRecord.name(of:))
            : ResultsEnd.detail(for: error)
        let thisSession = now().timeIntervalSince(session.startedAt)
        endResults(of: session, reason, testDuration: thisSession, detail: detail)
        sendEarlyEnd(
            of: session,
            reason,
            detail: detail,
            state: state,
            testDuration: session.earlierTestDuration + thisSession
        )
    }

    /// Removes what the run left beside and in the mutated project, last. The mutated project is kept, for a look after
    /// the run, but not the active-mutant file beside it, nor the helper link and the tests' `UserDefaults` of direct
    /// runs, nor its temporary folder, nor the derived data of xcodebuild's mutant runs, which holds one run's at most,
    /// nor the `.xctestrun` files of xcodebuild workers beyond the first. They go first: they take no time. Then the
    /// test-output folder, if empty, and the worker clones. Their simulators go once the work has ended
    /// (`SimulatorWorkerSetup`).
    private func removeWhatTheRunLeft(in state: AnyMutationTestState, session: TestingSession) {
        try? fileManager.removeItem(
            atPath: MutatedProjectNames.activationFolder(of: state.mutatedProjectDirectoryURL).path
        )
        if state.muterConfiguration.buildSystem == .swift {
            let activeMutantFile = MutationTestingDelegate.activeMutantFile(
                forWorkerIn: state.mutatedProjectDirectoryURL
            )
            try? fileManager.removeItem(atPath: activeMutantFile.path)
            DirectTestRun.removeOwnDefaults(forWorkerIn: state.mutatedProjectDirectoryURL)
            WorkerTemporaryFolder.remove(forWorkerIn: state.mutatedProjectDirectoryURL)
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
}
