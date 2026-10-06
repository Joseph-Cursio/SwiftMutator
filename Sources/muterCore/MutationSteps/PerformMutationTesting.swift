import Foundation
import SwiftSyntax

struct PerformMutationTesting: MutationStep {
    @Dependency(\.ioDelegate)
    private var ioDelegate: MutationTestingIODelegate
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
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

    private let buildErrorsThreshold: Int = 5

    /// With no `mutationTestTimeout`, a mutant's test run may take this many times the baseline run
    /// before it is stopped, but never less than `minimumDefaultTimeout` seconds. A mutant that makes
    /// the code loop forever then costs a few baseline runs rather than the whole run.
    static let defaultTimeoutMultiplier: TimeInterval = 3
    static let minimumDefaultTimeout: TimeInterval = 10

    /// Clones the mutated project for each extra parallel worker, and removes the clones afterwards.
    /// Injected so tests don't touch the disk.
    private let makeWorkerDirectories: (_ mutatedProject: URL, _ count: Int) throws -> [URL]
    private let removeWorkerDirectories: (_ directories: [URL]) -> Void

    init(
        makeWorkerDirectories: @escaping (URL, Int) throws -> [URL] = PerformMutationTesting.cloneMutatedProject,
        removeWorkerDirectories: @escaping ([URL]) -> Void = PerformMutationTesting.removeClones
    ) {
        self.makeWorkerDirectories = makeWorkerDirectories
        self.removeWorkerDirectories = removeWorkerDirectories
    }

    /// Tests every mutant, writing each one's result to the run's results file as it finishes, between a header
    /// and an end line that says how mutation testing ended.
    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)
        let session = TestingSession(startedAt: now())

        let mutations: [MutationTestOutcome.Mutation]
        do {
            mutations = try await performMutationTesting(using: state, session: session)
        } catch {
            endResults(
                of: session,
                error is CancellationError ? .interrupted : .aborted,
                detail: ResultsEnd.detail(for: error),
                testDuration: now().timeIntervalSince(session.startedAt)
            )
            throw error
        }

        let testDuration = now().timeIntervalSince(session.startedAt)
        endResults(of: session, .finished, testDuration: testDuration)

        let mutationTestOutcome = MutationTestOutcome(
            mutations: mutations,
            coverage: state.projectCoverage,
            testDuration: testDuration,
            newVersion: state.newVersion
        )

        notificationCenter.post(
            name: .mutationTestingFinished,
            object: mutationTestOutcome
        )

        return [.mutationTestOutcomeGenerated(mutationTestOutcome)]
    }
}

private extension PerformMutationTesting {
    func performMutationTesting(
        using state: AnyMutationTestState,
        session: TestingSession
    ) async throws -> [MutationTestOutcome.Mutation] {
        notificationCenter.post(name: .mutationTestingStarted, object: nil)

        // Only an explicit `true` asked for it, so only that is worth saying, and before the baseline run,
        // which can take minutes. Not a configuration error: the same configuration may be used with
        // another test command.
        if state.muterConfiguration.stopAtFirstFailure == true,
           let reason = state.muterConfiguration.stopAtFirstFailureUnsupportedReason {
            notificationCenter.post(name: .stopAtFirstFailureTurnedOff, object: reason)
        }

        let initialTime = Date()
        let (testSuiteOutcome, testLog) = await ioDelegate.benchmarkTests(
            using: state.muterConfiguration,
            savingResultsIntoFileNamed: "baseline run"
        )
        // Stopping the run kills the baseline run, which then fails, but that says nothing about the project's tests.
        try Task.checkCancellation()

        let timeAfterRunningTestSuite = Date()
        let timePerBuildTestCycle = DateInterval(
            start: initialTime,
            end: timeAfterRunningTestSuite
        ).duration

        let mutationLog = MutationTestLog(
            mutationPoint: .none,
            testLog: testLog,
            timePerBuildTestCycle: timePerBuildTestCycle,
            remainingMutationPointsCount: state.mutationPoints.count
        )

        guard testSuiteOutcome == .passed else {
            // A failing baseline is exactly when the user needs its output on disk, and nothing else
            // records it. It gets its own notification rather than `.newTestLogAvailable`, which also
            // announces that a baseline was successfully determined and starts the progress bar.
            notificationCenter.post(
                name: .baselineTestFailed,
                object: mutationLog
            )

            throw MuterError.mutationTestingAborted(
                reason: .baselineTestFailed(
                    log: testLog,
                    mutatedFilePaths: state.mutationMapping.map(\.filePath)
                )
            )
        }

        var muterConfiguration = state.muterConfiguration
        // A passing run can't show a failed test, so these tests print text shaped like one. Under a mutant it
        // could stop the run, or count a timed-out run killed, although every test passed, so such lines don't
        // count for this run. Checked whether or not runs stop at their first failed test, but worth a notice
        // only if they do, posted before the baseline's log, which starts the progress bar. Worker clones'
        // baselines keep the configuration as it was: a baseline is never stopped, and has no time limit.
        if let lookalike = FailedTestLine.first(inLog: testLog) {
            if muterConfiguration.stopsAtFirstFailure {
                notificationCenter.post(
                    name: .stopAtFirstFailureTurnedOff,
                    object: "the baseline run passed but printed a line that looks like a failed test:\n  \(lookalike)"
                )
            }
            muterConfiguration = muterConfiguration.withUnreliableFailedTestLines()
        }

        let configuration = muterConfiguration.withDefaultTestSuiteTimeout(
            max(timePerBuildTestCycle * Self.defaultTimeoutMultiplier, Self.minimumDefaultTimeout)
        )
        let jobs = state.mutationMapping.flatMap { mutationMap in
            mutationMap.mutationSchemata.map { MutantJob(fileName: mutationMap.fileName, schema: $0) }
        }
        let workers = min(configuration.workerCount, jobs.count)
        session.keys = MutantKey.keys(for: jobs.map(\.schema), under: state.mutatedProjectDirectoryURL)

        // Before the baseline's log, which starts the progress bar, so the results file's path is printed first.
        startResults(
            ResultsHeader(
                session: session.number,
                startedAt: session.startedAt,
                state: state,
                logDirectory: state.loggingDirectory,
                configuration: configuration,
                baselineSeconds: timePerBuildTestCycle,
                workers: workers,
                mutantsDiscovered: jobs.count,
                mutantsToTest: jobs.count,
                provenance: provenance(state.muterConfiguration)
            ),
            in: session,
            loggingDirectory: state.loggingDirectory
        )

        notificationCenter.post(
            name: .newTestLogAvailable,
            object: mutationLog
        )

        return workers > 1
            ? try await testMutationsInParallel(
                jobs, workers: workers, using: state, configuration: configuration, session: session
            )
            : try await testMutations(jobs, using: state, configuration: configuration, session: session)
    }

    struct MutantJob {
        let fileName: FileName
        let schema: MutationSchema
    }

    func testMutations(
        _ jobs: [MutantJob],
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws -> [MutationTestOutcome.Mutation] {
        var outcomes: [MutationTestOutcome.Mutation] = []
        outcomes.reserveCapacity(jobs.count)
        var buildErrors = 0

        for (index, job) in jobs.enumerated() {
            try Task.checkCancellation()
            try? await ioDelegate.switchOn(
                schemata: job.schema,
                for: state.projectXCTestRun,
                at: state.mutatedProjectDirectoryURL
            )

            let launched = instant()
            let run = await ioDelegate.runTestSuite(
                withSchemata: job.schema,
                using: configuration,
                savingResultsIntoFileNamed: logFileName(for: job.fileName, schemata: job.schema)
            )
            try Self.throwIfCancelled(run)

            outcomes.append(
                try record(
                    FinishedRun(index: index, worker: 0, run: run, seconds: seconds(since: launched)),
                    of: job,
                    using: state,
                    configuration: configuration,
                    session: session,
                    buildErrors: &buildErrors
                )
            )
        }

        return outcomes
    }

    /// Tests `jobs` on `workers` test processes at once, each in its own clone of the mutated project:
    /// `swift test` locks the package's build directory, so two runs can't share one. Every mutant is
    /// switched on per run: under `swift test` by the worker's active-mutant file, written just before the run
    /// (see `MutationTestingDelegate.testProcess`), so the clones' code never needs rewriting. Outcomes are
    /// recorded, and their notifications posted, as they finish; they're returned in `jobs` order. Once
    /// mutation testing is cancelled, no clone is made, no mutant starts, and none that returns is recorded.
    func testMutationsInParallel(
        _ jobs: [MutantJob],
        workers: Int,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession
    ) async throws -> [MutationTestOutcome.Mutation] {
        // A clone costs a copy and about one baseline build, which a stopped run would only throw away.
        try Task.checkCancellation()
        let clones: [URL]
        do {
            clones = try makeWorkerDirectories(state.mutatedProjectDirectoryURL, workers - 1)
        } catch {
            // Stopping the run kills a `cp` under way, which then fails.
            try Task.checkCancellation()
            throw error
        }
        defer { removeWorkerDirectories(clones) }
        try await buildWorkerDirectories(clones, using: state)
        let directories = [state.mutatedProjectDirectoryURL] + clones

        var outcomes = [MutationTestOutcome.Mutation?](repeating: nil, count: jobs.count)
        var buildErrors = 0

        try await withThrowingTaskGroup(of: FinishedRun.self) { group in
            var nextJob = 0
            // Throws once mutation testing is cancelled, rather than skip the job: with no run under way, the
            // loop below would end as if every mutant had been tested.
            func start(_ index: Int, worker: Int) throws {
                let job = jobs[index]
                let directory = directories[worker]
                let fileName = logFileName(for: job.fileName, schemata: job.schema)
                let started = group.addTaskUnlessCancelled {
                    let launched = instant()
                    let run = await ioDelegate.runTestSuite(
                        withSchemata: job.schema,
                        using: configuration,
                        savingResultsIntoFileNamed: fileName,
                        workingDirectory: directory
                    )
                    return FinishedRun(index: index, worker: worker, run: run, seconds: seconds(since: launched))
                }
                guard started else { throw CancellationError() }
            }

            for worker in directories.indices {
                try start(nextJob, worker: worker)
                nextJob += 1
            }

            while let finished = try await group.next() {
                // Throwing cancels the other runs, whose cancellation handlers kill their process trees.
                try Self.throwIfCancelled(finished.run)
                outcomes[finished.index] = try record(
                    finished,
                    of: jobs[finished.index],
                    using: state,
                    configuration: configuration,
                    session: session,
                    buildErrors: &buildErrors
                )
                // The worker that finished takes the next job; the directory is looked up from it.
                if nextJob < jobs.count {
                    try start(nextJob, worker: finished.worker)
                    nextJob += 1
                }
            }
        }

        return outcomes.compactMap { $0 }
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
        let runs = await withTaskGroup(of: (worker: Int, outcome: TestSuiteOutcome, testLog: String).self) { group in
            for (index, clone) in clones.enumerated() {
                group.addTask {
                    let run = await ioDelegate.benchmarkTests(
                        using: state.muterConfiguration,
                        savingResultsIntoFileNamed: "baseline run worker \(index + 1)",
                        workingDirectory: clone
                    )
                    return (index + 1, run.outcome, run.testLog)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        try Task.checkCancellation()

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

    /// The seconds from `start` to now, on the monotonic clock.
    func seconds(since start: DispatchTime) -> TimeInterval {
        let end = instant()
        guard end >= start else { return 0 }
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// Writes `finished`'s result, the run of `job`'s mutant, to the results file, builds its outcome, posts its
    /// notifications, and aborts after `buildErrorsThreshold` build errors in a row. The result is written first,
    /// so it is on disk before anything else happens, the abort included.
    func record(
        _ finished: FinishedRun,
        of job: MutantJob,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration,
        session: TestingSession,
        buildErrors: inout Int
    ) throws -> MutationTestOutcome.Mutation {
        let mutationPoint = MutationPoint(
            mutationOperatorId: job.schema.mutationOperatorId,
            filePath: job.schema.filePath,
            position: job.schema.position
        )

        write(
            MutantResult(
                key: session.keys[finished.index],
                schema: job.schema,
                finished: finished,
                configuration: configuration,
                session: session.number,
                finishedAt: now(),
                log: MutationTestLog.keptFileName(for: mutationPoint)
            ),
            in: session
        )
        session.recorded += 1

        let outcome = MutationTestOutcome.Mutation(
            testSuiteOutcome: finished.run.outcome,
            mutationPoint: mutationPoint,
            mutationSnapshot: job.schema.snapshot,
            originalProjectDirectoryUrl: state.projectDirectoryURL,
            mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
        )

        let mutationLog = MutationTestLog(
            mutationPoint: mutationPoint,
            testLog: finished.run.testLog,
            timePerBuildTestCycle: .none,
            remainingMutationPointsCount: .none
        )

        notificationCenter.post(
            name: .newMutationTestOutcomeAvailable,
            object: outcome
        )

        notificationCenter.post(
            name: .newTestLogAvailable,
            object: mutationLog
        )

        buildErrors = finished.run.outcome == .buildError ? (buildErrors + 1) : 0
        if buildErrors >= buildErrorsThreshold {
            throw MuterError.mutationTestingAborted(reason: .tooManyBuildErrors)
        }
        return outcome
    }

    func logFileName(
        for fileName: FileName,
        schemata: MutationSchema
    ) -> String {
        "\(fileName)_\(schemata.mutationOperatorId.rawValue)_\(schemata.position).log"
    }
}

/// The run's results file: a header once the baseline passes, a line for each tested mutant as it finishes, and an
/// end line however mutation testing ends.
private extension PerformMutationTesting {
    /// Creates the results file in the run's log folder, and writes `header` to it. Without one the run goes on: the
    /// report at the end doesn't need it. A state without a log folder, which a test that bypasses the handler
    /// makes, writes none, and the header isn't made.
    func startResults(
        _ header: @autoclosure () -> ResultsHeader,
        in session: TestingSession,
        loggingDirectory: String
    ) {
        guard !loggingDirectory.isEmpty else { return }
        do {
            let results = try resultsFiles.create(in: loggingDirectory)
            session.results = results
            if write(header(), in: session) {
                notificationCenter.post(name: .resultsFileCreated, object: results.path)
            }
        } catch {
            notificationCenter.post(name: .resultsFileUnavailable, object: "\(error)")
        }
    }

    /// Appends `line` to the session's results file, if it has one. After a failed write no line is written, or even
    /// built, and the failure is said once.
    @discardableResult
    func write<Line: Encodable>(_ line: @autoclosure () -> Line, in session: TestingSession) -> Bool {
        guard let results = session.results, results.writeError == nil else { return false }
        if results.append(line()) {
            return true
        }
        if !session.saidResultsUnwritable {
            session.saidResultsUnwritable = true
            notificationCenter.post(
                name: .resultsFileUnavailable,
                object: results.writeError.map { "\($0)" } ?? "a write to \(results.path) failed"
            )
        }
        return false
    }

    /// Writes the session's end line, and closes its results file, which releases the file's lock.
    func endResults(
        of session: TestingSession,
        _ reason: ResultsEnd.Reason,
        detail: String? = nil,
        testDuration: TimeInterval
    ) {
        write(
            ResultsEnd(
                session: session.number,
                endedAt: now(),
                reason: reason,
                detail: detail,
                testDurationSeconds: testDuration,
                recorded: session.recorded
            ),
            in: session
        )
        session.results?.close()
    }
}

extension PerformMutationTesting {
    struct WorkerDirectoryError: Error, CustomStringConvertible {
        let clone: URL
        let status: Int32

        var description: String {
            "SwiftMutator could not clone the mutated project to \(clone.path) for a parallel worker (cp exited \(status))."
        }
    }

    /// One clone of `project` per extra worker, next to it as `<name>_worker<n>`. On macOS `cp -c`
    /// clones on APFS, so even a large build directory copies in seconds. Each clone is then built once
    /// before testing (`buildWorkerDirectories`). Every path in it has changed, so that is a full build:
    /// about one baseline build of time, and much of the clone's build directory is rewritten rather
    /// than shared. Its copied Clang module caches record the mutated project's path, so they're
    /// discarded first, as `CopyProjectToTempDirectory` does for the mutated project itself.
    static func cloneMutatedProject(_ project: URL, count: Int) throws -> [URL] {
        try cloneMutatedProject(project, count: count, copying: copyProject(_:to:))
    }

    /// `copy` copies the project to one clone. If one fails, the clones made before it are removed, and so is whatever
    /// the failed copy left: nothing else would remove them until a later parallel run replaced them.
    static func cloneMutatedProject(
        _ project: URL,
        count: Int,
        copying copy: (_ project: URL, _ clone: URL) throws -> Void
    ) throws -> [URL] {
        guard count > 0 else { return [] }
        var clones: [URL] = []
        do {
            for index in 1...count {
                let clone = project.deletingLastPathComponent()
                    .appendingPathComponent("\(project.lastPathComponent)_worker\(index)")
                try? FileManager.default.removeItem(at: clone)
                clones.append(clone) // before the copy, which can fail partway through
                try copy(project, clone)
                discardModuleCaches(in: clone)
            }
            return clones
        } catch {
            removeClones(clones)
            throw error
        }
    }

    private static func copyProject(_ project: URL, to clone: URL) throws {
        #if os(macOS)
        let copy = Foundation.Process()
        copy.executableURL = URL(fileURLWithPath: "/bin/cp")
        copy.arguments = ["-c", "-R", project.path, clone.path]
        try copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else {
            throw WorkerDirectoryError(clone: clone, status: copy.terminationStatus)
        }
        #else
        try FileManager.default.copyItem(at: project, to: clone)
        #endif
    }

    static func discardModuleCaches(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
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

    static func removeClones(_ directories: [URL]) {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
