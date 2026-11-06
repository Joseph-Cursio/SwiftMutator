import Foundation

/// The clones of the mutated project that a SwiftPM run's workers beyond the first test in, made before its mutants
/// and removed after them.
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

    /// `workers`, the SwiftPM workers that are to test `plan`'s mutants, with their clones made and built, or one
    /// worker when `configuration` gives no count and they can't be: a suite that can't run beside a copy of itself, or
    /// a project that can't be copied, shouldn't fail only for the default. With a count that was asked for it throws,
    /// and the run stops. So does a stop.
    func clonesMade(
        for workers: SimulatorWorkerSetup.Workers,
        testing plan: ResumePlan,
        configuration: MuterConfiguration,
        state: AnyMutationTestState,
        session: TestingSession
    ) async throws -> SimulatorWorkerSetup.Workers {
        do {
            // A clone costs a copy and about one baseline build, which a stopped run would only throw away.
            try Task.checkCancellation()
            try await cloneWorkers(workers.count, using: state, session: session)
            return workers
        } catch {
            guard configuration.mutationTestWorkers == nil, !(error is CancellationError) else { throw error }
            if !session.clones.isEmpty {
                removeWorkerDirectories(session.clones)
                session.clones = []
            }
            let why = Self.whyOneWorker(afterClonesFailedWith: error)
            events.send(.workersChosen(WorkerChoice(
                configuration, used: 1, mutantsToTest: plan.toRun.count, unsupportedReason: why
            )))
            return SimulatorWorkerSetup.Workers(
                count: 1, unavailable: why, configuration: workers.configuration, xcodeWorkers: []
            )
        }
    }

    /// Why a run with the default count of workers tests on one, after `error` made it give up its clones. Completes
    /// the sentence "Testing one mutant at a time instead: …".
    static func whyOneWorker(afterClonesFailedWith error: Error) -> String {
        guard case let .mutationTestingAborted(reason: .workerBaselineTestFailed(worker, _, _))? = error as? MuterError
        else {
            return "\(error) `mutationTestWorkers: 1` skips trying"
        }
        return "worker \(worker)'s copy of the project didn't pass the baseline the first one passed (its log is "
            + "baseline run worker \(worker).log), so your tests may not run beside a copy of themselves, or the "
            + "builds ran out of disk space or memory. `mutationTestWorkers: 1` skips trying"
    }

    /// A clone of the mutated project for each of `count` SwiftPM workers but the first, which tests in the project
    /// itself, built, and kept in `session`.
    func cloneWorkers(
        _ count: Int,
        using state: AnyMutationTestState,
        session: TestingSession
    ) async throws {
        let clones: [URL]
        do {
            clones = try await makeWorkerDirectories(state.mutatedProjectDirectoryURL, count - 1)
        } catch {
            // Stopping the run kills a `cp` under way, which then fails.
            try Task.checkCancellation()
            throw error
        }
        session.clones = clones
        try await buildWorkerDirectories(clones, using: state)
    }

    /// Builds each worker clone once, by running the baseline test command in it. A clone is copied
    /// after the mutated project was built, and `swift test --skip-build` would otherwise run the test
    /// binaries built there: `#filePath` and every other path compiled into them would still point into
    /// the mutated project, so tests that write files next to their sources would share those files
    /// across workers, fail each other, and kill mutants they never tested. A clone whose baseline
    /// doesn't pass throws, naming the worker: the same command just passed in the mutated
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
            let name = "baseline run worker \(run.worker)"
            fileManager.keepLog(
                run.testLog,
                writtenTo: testOutput(named: name, state: state),
                by: ioDelegate,
                named: name + ".log",
                state: state
            )
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

    /// One clone of `project` per extra worker, next to it as `<stem>_worker<n>.noindex`
    /// (`MutatedProjectNames.clone(_:of:)`). On macOS `cp -c`
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
                let clone = MutatedProjectNames.clone(index, of: project)
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

    /// Removes each clone, the active-mutant file, helper link and activation folder beside it, its temporary folder,
    /// and its tests' `UserDefaults`, on a thread of its own: one large clone takes a fraction of a second or more to
    /// remove, and a run that is stopping does this last, when a second signal exits at once and leaves the rest
    /// behind.
    static func removeClones(_ directories: [URL]) {
        DispatchQueue.concurrentPerform(iterations: directories.count) { index in
            let clone = directories[index]
            try? FileManager.default.removeItem(at: MutationTestingDelegate.activeMutantFile(forWorkerIn: clone))
            try? FileManager.default.removeItem(at: MutatedProjectNames.activationFolder(of: clone))
            DirectTestRun.removeOwnDefaults(forWorkerIn: clone)
            WorkerTemporaryFolder.remove(forWorkerIn: clone)
            try? FileManager.default.removeItem(at: clone)
        }
    }
}
