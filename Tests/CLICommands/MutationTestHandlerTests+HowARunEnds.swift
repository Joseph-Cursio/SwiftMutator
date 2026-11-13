@testable import muterCore
import TestingExtensions
import XCTest

extension MutationTestHandlerTests {
    /// A step that refuses a resume, as `LoadResumeState` and `FingerprintProjectTree` do.
    private final class RefusingStep: MutationStep {
        func run(with _: AnyMutationTestState) throws -> [MutationTestState.Change] {
            throw ResumeRefused(
                path: "/logs/results.jsonl",
                reasons: [.inUse(holder: nil, lastProcess: nil, lastHost: nil)],
                beforeTheCopy: true
            )
        }
    }

    /// A step that notes the state's log folder as it runs, since the state is shared and could change after it.
    private final class LoggingDirectoryProbe: MutationStep {
        private(set) var loggingDirectories: [String] = []

        func run(with state: AnyMutationTestState) throws -> [MutationTestState.Change] {
            loggingDirectories.append(state.loggingDirectory)
            return []
        }
    }

    /// A step that, as it runs, is stopped at once by a SIGINT, as a second Ctrl-C does.
    private struct BuildForTestingStandIn: MutationStep {
        let interruption: InterruptionRecord

        func run(with _: AnyMutationTestState) throws -> [MutationTestState.Change] {
            _ = interruption.record(SIGINT)
            interruption.stoppingAtOnce()
            throw CancellationError()
        }
    }

    // A failed baseline's kind of abort leaves a results file of its own in the run's log folder, which says why, and
    // the run says where; any other error leaves none.
    func test_aRunThatStopsOnAFailedBaseline_recordsWhy_inItsLogFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        stepSpy1.resultToReturn = .success([.projectDirectoryUrlDiscovered(URL(fileURLWithPath: "/project"))])
        stepSpy2.resultToReturn = .failure(.mutationTestingAborted(
            reason: .baselineTestFailed(log: "error: no such module", mutatedFilePaths: [])
        ))
        var said: [String] = []
        let observer = runEvents.observe(.stoppedRunRecorded) { event in
            if case let .stoppedRunRecorded(path) = event { said.append(path) }
        }
        defer { observer.cancel() }

        await assertThrowsMuterError(try await sut.run()) { _ in }

        let record = try XCTUnwrap(resultsFiles.records(ResultsStopped.self).first)
        // From the abort, whatever step threw it.
        XCTAssertEqual(record.step, .baseline)
        XCTAssertEqual(record.reason, .failed)
        XCTAssertEqual(record.projectPath, "/project")
        XCTAssertEqual(record.logDirectory, state.loggingDirectory)
        XCTAssertEqual(resultsFiles.directories, [state.loggingDirectory])
        XCTAssertEqual(said, ["\(state.loggingDirectory)/results.jsonl"])
    }

    func test_aRunThatStopsOnAnyOtherError_recordsNothing() async throws {
        givenThereIsAFailureInOneOfItsSteps()

        await assertThrowsMuterError(try await sut.run()) { _ in }

        XCTAssertEqual(resultsFiles.directories, [])
    }

    // A signal wins over the error the stopped step threw, as it does the exit status: a baseline it killed fails.
    func test_aRunASignalStops_recordsTheSignal() async throws {
        givenThereAreNoFailuresInAnyOfItSteps()
        let interruption = current.interruption
        stepSpy2.whileRunning = {
            _ = interruption.record(SIGTERM)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        stepSpy2.resultToReturn = .failure(.mutationTestingAborted(
            reason: .baselineTestFailed(log: "killed", mutatedFilePaths: [])
        ))

        nonisolated(unsafe) let handler = sut
        _ = await Task { try await handler.run() }.result

        let record = try XCTUnwrap(resultsFiles.records(ResultsStopped.self).first)
        XCTAssertEqual(record.reason, .interrupted)
        XCTAssertEqual(record.detail, "SIGTERM")
    }

    // A stop at once, from the signal's thread, during a step before mutation testing, as a second Ctrl-C during a
    // long build, records the run too, with the step it was in.
    func test_aStopAtOnceDuringAStep_isRecorded() async throws {
        givenThereAreNoFailuresInAnyOfItSteps()
        let interruption = current.interruption
        let handler = MutationTestHandler(
            steps: [stepSpy1, BuildForTestingStandIn(interruption: interruption)], state: state
        )

        _ = try? await handler.run()

        let record = try XCTUnwrap(resultsFiles.records(ResultsStopped.self).first)
        XCTAssertEqual(record.step, .preparing)
        XCTAssertEqual(record.detail, "SIGINT")
    }

    // A run that makes a test plan tests no mutant, so it records nothing, however it stops.
    func test_aRunThatMakesATestPlan_recordsNothing() async throws {
        stepSpy1.resultToReturn = .failure(.mutationTestingAborted(
            reason: .baselineTestFailed(log: "", mutatedFilePaths: [])
        ))
        let handler = MutationTestHandler(options: .make(createTestPlan: true), steps: [stepSpy1], state: state)

        _ = try? await handler.run()

        XCTAssertEqual(resultsFiles.directories, [])
    }

    func test_theStepsAStoppedRunNames() {
        XCTAssertEqual(MutationTestHandler.stoppedRunStep(of: DiscoverProjectCoverage()), .coverageRun)
        XCTAssertEqual(MutationTestHandler.stoppedRunStep(of: BuildForTesting()), .buildForTesting)
        // From its baseline on, mutation testing names its own steps.
        XCTAssertEqual(MutationTestHandler.stoppedRunStep(of: PerformMutationTesting()), .preparing)
        XCTAssertEqual(MutationTestHandler.stoppedRunStep(of: DiscoverSourceFiles()), .preparing)
    }

    // Every step, the first included, finds the folder the observer keeps the run's test logs in, so a step can
    // keep other files of the run beside them.
    func test_theRunsLogFolderReachesTheStateBeforeTheFirstStep() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        let firstStep = LoggingDirectoryProbe()
        stepSpy1.resultToReturn = .success([])
        sut = MutationTestHandler(steps: [firstStep, stepSpy1], state: state)

        try await sut.run()

        // The logs' root first, then the run's folder in it.
        XCTAssertEqual(fileManager.paths.first, "/project_muter_logs")
        let loggingDirectory = try XCTUnwrap(fileManager.paths.dropFirst().first)
        XCTAssertTrue(loggingDirectory.hasPrefix("/project_muter_logs/"), loggingDirectory)
        XCTAssertEqual(firstStep.loggingDirectories, [loggingDirectory])
        XCTAssertEqual(state.loggingDirectory, loggingDirectory)
    }

    // A refused or failed run keeps nothing in its log folder, and leaves no empty folder behind for each refusal.
    func test_aRefusedRun_removesItsEmptyLogFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        givenThereIsAFailureInOneOfItsSteps()

        try await assertThrowsMuterError(await sut.run()) { error in
            guard case .configurationParsingError = error else {
                XCTFail("Expected configurationParsingError, got \(error)")
                return
            }
        }

        assertTheRunsLogFolderIsRemoved()
    }

    // A resume refused is removed the same way, whichever step refuses it.
    func test_aRefusedResume_removesItsEmptyLogFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        stepSpy1.resultToReturn = .success([])
        sut = MutationTestHandler(steps: [stepSpy1, RefusingStep(), stepSpy2], state: state)

        await AssertThrowsError(try await sut.run()) { XCTAssertTrue($0 is ResumeRefused, "\($0)") }

        XCTAssertTrue(stepSpy2.methodCalls.isEmpty)
        assertTheRunsLogFolderIsRemoved()
    }

    func test_aRunThatKeptALog_keepsItsLogFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        fileManager.contentsOfDirectoryToReturn = ["baseline run.log"]
        givenThereIsAFailureInOneOfItsSteps()

        try await assertThrowsMuterError(await sut.run()) { _ in }

        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, [state.loggingDirectory])
        XCTAssertFalse(fileManager.methodCalls.contains("removeItem(atPath:)"), "\(fileManager.methodCalls)")
    }

    func test_aStoppedRun_removesItsEmptyLogFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        givenThereAreNoFailuresInAnyOfItSteps()
        stepSpy1.whileRunning = { withUnsafeCurrentTask { $0?.cancel() } }

        // The test waits for the task, so until it ends only the task uses the handler, its steps and its state.
        nonisolated(unsafe) let handler = sut
        let result = await Task { try await handler.run() }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        assertTheRunsLogFolderIsRemoved()
    }

    // Such as `mutate-without-running --skip-coverage`. A resumed session with nothing left to test keeps the note it
    // leaves there.
    func test_aRunThatFinishedWithNothingKept_removesItsLogFolder() async throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        givenThereAreNoFailuresInAnyOfItSteps()

        try await sut.run()

        assertTheRunsLogFolderIsRemoved()
    }

    // The verdict the run exits with, from the observer, which judged the outcome its last step sent.
    func test_aFinishedRun_givesItsVerdictOnItsScore() async throws {
        givenThereAreNoFailuresInAnyOfItSteps()
        stepSpy3.whileRunning = { [runEvents] in
            runEvents.send(.mutationTestingFinished(.make([.failed, .passed], failUnder: 80)))
        }

        let gate = try await sut.run().scoreGate

        XCTAssertEqual(gate?.verdict, .failed)
        XCTAssertEqual(gate?.failUnder, 80)
    }

    func test_aFinishedRunWithoutAThreshold_givesNoVerdict() async throws {
        givenThereAreNoFailuresInAnyOfItSteps()
        stepSpy3.whileRunning = { [runEvents] in
            runEvents.send(.mutationTestingFinished(.make([.failed, .passed])))
        }

        let checks = try await sut.run()

        XCTAssertEqual(checks, RunChecks())
        XCTAssertTrue(checks.isEmpty)
    }

    /// Asserts that the run listed its own log folder at the end, found it empty and removed it, and only it: the
    /// logs' root, which another run may be claiming a folder in, stays.
    func assertTheRunsLogFolderIsRemoved(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            state.loggingDirectory.hasPrefix("/project_muter_logs/"),
            state.loggingDirectory,
            file: file,
            line: line
        )
        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, [state.loggingDirectory], file: file, line: line)
        XCTAssertEqual(fileManager.methodCalls.last, "removeItem(atPath:)", file: file, line: line)
        XCTAssertEqual(fileManager.methodCalls.filter { $0 == "removeItem(atPath:)" }.count, 1, file: file, line: line)
        XCTAssertEqual(fileManager.paths.last, state.loggingDirectory, file: file, line: line)
    }

    // A run refused by another run of the project, or by any step before the lock, prunes no log folder; one that
    // gets past the lock does.
    func test_aRunRefusedBeforeTheLock_prunesNoLogFolder() async throws {
        current.mutatedProjectLocker = MutatedProjectLock.Locker()
        let project = URL(fileURLWithPath: try makeTemporaryDirectory()).appendingPathComponent("x")
        let pruned = Locked(0)
        let steps = { (before: [MutationStep]) -> [MutationStep] in
            before + [
                CreateMutatedProjectDirectoryURL(),
                LockMutatedProject(),
                PruneLogFolders { root, _, _, keeping in
                    pruned.change { $0 += 1 }
                    return LogFolderPruning(root: root, keeping: keeping)
                },
            ]
        }
        let givenState = { () -> MutationTestState in
            let made = MutationTestState()
            made.projectDirectoryURL = project
            made.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", keepLogFolders: 2)
            return made
        }
        // As an older SwiftMutator, whose copy has no `.noindex`, holds it: it locks the same file.
        let other = try MutatedProjectLock.Locker().lock(URL(fileURLWithPath: project.path + "_mutated"))
        let locked = MutationTestHandler(steps: steps([]), state: givenState())
        let refused = MutationTestHandler(steps: steps([RefusingStep()]), state: givenState())

        await AssertThrowsError(try await locked.run()) { XCTAssertTrue($0 is MutatedProjectLockError, "\($0)") }
        await AssertThrowsError(try await refused.run()) { XCTAssertTrue($0 is ResumeRefused, "\($0)") }
        XCTAssertEqual(pruned.value, 0)

        other.release()
        try await MutationTestHandler(steps: steps([]), state: givenState()).run()
        XCTAssertEqual(pruned.value, 1)
    }
}
