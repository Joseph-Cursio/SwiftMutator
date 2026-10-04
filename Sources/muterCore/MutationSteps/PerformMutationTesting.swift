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

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)

        let (mutationOutcome, testDuration) = try await benchmarkMutationTesting {
            try await performMutationTesting(using: state)
        }

        let mutationTestOutcome = MutationTestOutcome(
            mutations: mutationOutcome,
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

    private func benchmarkMutationTesting<T>(
        _ work: () async throws -> T
    ) async throws -> (result: T, duration: TimeInterval) {
        let initialTime = now()
        let result = try await work()
        let duration = DateInterval(
            start: initialTime,
            end: now()
        ).duration

        return (result, duration)
    }
}

private extension PerformMutationTesting {
    func performMutationTesting(
        using state: AnyMutationTestState
    ) async throws -> [MutationTestOutcome.Mutation] {
        notificationCenter.post(name: .mutationTestingStarted, object: nil)

        let initialTime = Date()
        let (testSuiteOutcome, testLog) = await ioDelegate.benchmarkTests(
            using: state.muterConfiguration,
            savingResultsIntoFileNamed: "baseline run"
        )

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

        notificationCenter.post(
            name: .newTestLogAvailable,
            object: mutationLog
        )

        let configuration = muterConfiguration.withDefaultTestSuiteTimeout(
            max(timePerBuildTestCycle * Self.defaultTimeoutMultiplier, Self.minimumDefaultTimeout)
        )
        let jobs = state.mutationMapping.flatMap { mutationMap in
            mutationMap.mutationSchemata.map { MutantJob(fileName: mutationMap.fileName, schema: $0) }
        }
        let workers = min(configuration.workerCount, jobs.count)

        return workers > 1
            ? try await testMutationsInParallel(jobs, workers: workers, using: state, configuration: configuration)
            : try await testMutations(jobs, using: state, configuration: configuration)
    }

    struct MutantJob {
        let fileName: FileName
        let schema: MutationSchema
    }

    func testMutations(
        _ jobs: [MutantJob],
        using state: AnyMutationTestState,
        configuration: MuterConfiguration
    ) async throws -> [MutationTestOutcome.Mutation] {
        var outcomes: [MutationTestOutcome.Mutation] = []
        outcomes.reserveCapacity(jobs.count)
        var buildErrors = 0

        for job in jobs {
            try? await ioDelegate.switchOn(
                schemata: job.schema,
                for: state.projectXCTestRun,
                at: state.mutatedProjectDirectoryURL
            )

            let (testSuiteOutcome, testLog) = await ioDelegate.runTestSuite(
                withSchemata: job.schema,
                using: configuration,
                savingResultsIntoFileNamed: logFileName(for: job.fileName, schemata: job.schema)
            )

            outcomes.append(
                try record(job, testSuiteOutcome, testLog, using: state, buildErrors: &buildErrors)
            )
        }

        return outcomes
    }

    /// Tests `jobs` on `workers` test processes at once, each in its own clone of the mutated project:
    /// `swift test` locks the package's build directory, so two runs can't share one. Every mutant is
    /// switched on by its own process's environment, so the clones never need rewriting. Outcomes are
    /// recorded, and their notifications posted, as they finish; they're returned in `jobs` order.
    func testMutationsInParallel(
        _ jobs: [MutantJob],
        workers: Int,
        using state: AnyMutationTestState,
        configuration: MuterConfiguration
    ) async throws -> [MutationTestOutcome.Mutation] {
        let clones = try makeWorkerDirectories(state.mutatedProjectDirectoryURL, workers - 1)
        defer { removeWorkerDirectories(clones) }
        try await buildWorkerDirectories(clones, using: state)
        let directories = [state.mutatedProjectDirectoryURL] + clones

        var outcomes = [MutationTestOutcome.Mutation?](repeating: nil, count: jobs.count)
        var buildErrors = 0

        try await withThrowingTaskGroup(
            of: (index: Int, directory: URL, outcome: TestSuiteOutcome, log: String).self
        ) { group in
            var nextJob = 0
            func start(_ index: Int, in directory: URL) {
                let job = jobs[index]
                let fileName = logFileName(for: job.fileName, schemata: job.schema)
                group.addTask {
                    let (outcome, log) = await ioDelegate.runTestSuite(
                        withSchemata: job.schema,
                        using: configuration,
                        savingResultsIntoFileNamed: fileName,
                        workingDirectory: directory
                    )
                    return (index, directory, outcome, log)
                }
            }

            for directory in directories {
                start(nextJob, in: directory)
                nextJob += 1
            }

            while let finished = try await group.next() {
                outcomes[finished.index] = try record(
                    jobs[finished.index], finished.outcome, finished.log,
                    using: state, buildErrors: &buildErrors
                )
                if nextJob < jobs.count {
                    start(nextJob, in: finished.directory)
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
    /// project, so the configuration isn't what's wrong.
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

    /// Builds `job`'s outcome, posts its notifications, and aborts after `buildErrorsThreshold`
    /// build errors in a row.
    func record(
        _ job: MutantJob,
        _ testSuiteOutcome: TestSuiteOutcome,
        _ testLog: String,
        using state: AnyMutationTestState,
        buildErrors: inout Int
    ) throws -> MutationTestOutcome.Mutation {
        let mutationPoint = MutationPoint(
            mutationOperatorId: job.schema.mutationOperatorId,
            filePath: job.schema.filePath,
            position: job.schema.position
        )

        let outcome = MutationTestOutcome.Mutation(
            testSuiteOutcome: testSuiteOutcome,
            mutationPoint: mutationPoint,
            mutationSnapshot: job.schema.snapshot,
            originalProjectDirectoryUrl: state.projectDirectoryURL,
            mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
        )

        let mutationLog = MutationTestLog(
            mutationPoint: mutationPoint,
            testLog: testLog,
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

        buildErrors = testSuiteOutcome == .buildError ? (buildErrors + 1) : 0
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
        guard count > 0 else { return [] }
        return try (1...count).map { index in
            let clone = project.deletingLastPathComponent()
                .appendingPathComponent("\(project.lastPathComponent)_worker\(index)")
            try? FileManager.default.removeItem(at: clone)
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
            discardModuleCaches(in: clone)
            return clone
        }
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
