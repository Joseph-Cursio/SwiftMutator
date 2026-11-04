@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class MutationTestHandlerTests: MuterTestCase {
    private let stepSpy1 = MutationStepSpy()
    private let stepSpy2 = MutationStepSpy()
    private let stepSpy3 = MutationStepSpy()
    private let state = MutationTestState()

    private lazy var sut = MutationTestHandler(
        steps: [stepSpy1, stepSpy2, stepSpy3],
        state: state
    )

    func test_whenThereAreNoFailuresInAnyOfItSteps() async throws {
        givenThereAreNoFailuresInAnyOfItSteps()

        let expectedState = state

        try await sut.run()

        let assertThatRunsAllItsSteps = {
            XCTAssertEqual(self.stepSpy1.methodCalls, ["run(with:)"])
            XCTAssertEqual(self.stepSpy2.methodCalls, ["run(with:)"])
            XCTAssertEqual(self.stepSpy3.methodCalls, ["run(with:)"])
        }

        let assertThatAllStepsShareTheState = {
            XCTAssertTrue(self.stepSpy1.states.first === expectedState)
            XCTAssertTrue(self.stepSpy2.states.first === expectedState)
            XCTAssertTrue(self.stepSpy3.states.first === expectedState)
        }

        let assertThatReturnsSuccess = {
            XCTAssertEqual(expectedState.mutatedProjectDirectoryURL, URL(string: "/lol/son")!)
            XCTAssertEqual(expectedState.projectDirectoryURL, URL(string: "/lol")!)
        }

        assertThatRunsAllItsSteps()
        assertThatAllStepsShareTheState()
        assertThatReturnsSuccess()
    }

    private func givenThereAreNoFailuresInAnyOfItSteps() {
        stepSpy1.resultToReturn = .success([.tempDirectoryUrlCreated(URL(string: "/lol/son")!)])
        stepSpy2.resultToReturn = .success([.projectDirectoryUrlDiscovered(URL(string: "/lol")!)])
        stepSpy3.resultToReturn = .success([])
    }

    func test_whenThereIsAFailureInOneOfItsSteps() async throws {
        givenThereIsAFailureInOneOfItsSteps()

        try await assertThrowsMuterError(
            await sut.run()
        ) { error in
            guard case let .configurationParsingError(reason) = error else {
                XCTFail("Expected configurationParsingError, got \(error)")
                return
            }

            XCTAssertFalse(reason.isEmpty)
        }

        let assertThatNoStepRunsAfterTheFailingOne = {
            XCTAssertEqual(self.stepSpy1.methodCalls, ["run(with:)"])
            XCTAssertEqual(self.stepSpy2.methodCalls, ["run(with:)"])
            XCTAssertTrue(self.stepSpy3.methodCalls.isEmpty)
        }

        let assertThatNoLaterStepGetsTheState = {
            XCTAssertTrue(self.stepSpy1.states.first === self.state)
            XCTAssertTrue(self.stepSpy2.states.first === self.state)
            XCTAssertTrue(self.stepSpy3.states.isEmpty)
        }

        assertThatNoStepRunsAfterTheFailingOne()
        assertThatNoLaterStepGetsTheState()
    }

    private func givenThereIsAFailureInOneOfItsSteps() {
        stepSpy1.resultToReturn = .success([])
        stepSpy2.resultToReturn = .failure(.configurationParsingError(reason: "some reason"))
        stepSpy3.resultToReturn = .success([])
    }

    // A later step would go on from what the stopped one left half done, and could start processes that stopping
    // the run would then have to kill.
    func test_whenCancelledDuringAStep_noLaterStepRuns() async throws {
        givenThereAreNoFailuresInAnyOfItSteps()
        stepSpy1.whileRunning = { withUnsafeCurrentTask { $0?.cancel() } }

        // The test waits for the task, so until it ends only the task uses the handler, its steps and its state.
        nonisolated(unsafe) let handler = sut
        let result = await Task { try await handler.run() }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(stepSpy1.methodCalls, ["run(with:)"])
        XCTAssertTrue(stepSpy2.methodCalls.isEmpty)
        XCTAssertTrue(stepSpy3.methodCalls.isEmpty)
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

    /// Asserts that the run listed its own log folder at the end, found it empty and removed it, and only it: the
    /// logs' root, which another run may be claiming a folder in, stays.
    private func assertTheRunsLogFolderIsRemoved(file: StaticString = #filePath, line: UInt = #line) {
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

    func test_allSteps() {
        sut = MutationTestHandler(options: .make())

        XCTAssertEqual(sut.steps.count, 15)

        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CopyProjectToTempDirectory.self)
        // Right after the copy: discovery rewrites the copy's files within milliseconds of starting.
        XCTAssertTypeEqual(sut.steps[safe: 6], FingerprintProjectTree.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], ApplySchemata.self)
        XCTAssertTypeEqual(sut.steps[safe: 12], CheckMutantSwitches.self)
        XCTAssertTypeEqual(sut.steps[safe: 13], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 14], PerformMutationTesting.self)
    }

    func test_steps_whenResuming() {
        sut = MutationTestHandler(options: .make(resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")))

        XCTAssertEqual(sut.steps.count, 16)

        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadResumeState.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], CopyProjectToTempDirectory.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], FingerprintProjectTree.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 15], PerformMutationTesting.self)
    }

    // A reuse loads the earlier run's results file where a resume does, so it's refused as early.
    func test_steps_whenReusing_loadTheEarlierRunsResults_whereAResumeDoes() {
        let reusing = MutationTestHandler(options: .make(reuseURL: URL(fileURLWithPath: "/logs/results.jsonl")))
        let resuming = MutationTestHandler(options: .make(resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")))

        XCTAssertEqual(reusing.steps.map { "\(type(of: $0))" }, resuming.steps.map { "\(type(of: $0))" })
    }

    // A run still writing the results file tests in the copy that cleaning up removes, and a refused resume should
    // leave everything as it was.
    func test_loadResumeState_comesBeforeCleanUpAndCopy() throws {
        sut = MutationTestHandler(
            options: .make(skipCoverage: true, skipUpdateCheck: true, resumeURL: URL(fileURLWithPath: "/logs"))
        )
        let index = { (step: MutationStep.Type) in self.sut.steps.firstIndex { type(of: $0) == step } }

        let loading = try XCTUnwrap(index(LoadResumeState.self))
        XCTAssertLessThan(try XCTUnwrap(index(LoadConfiguration.self)), loading, "it compares the configuration")
        XCTAssertLessThan(loading, try XCTUnwrap(index(PreviousRunCleanUp.self)))
        XCTAssertLessThan(loading, try XCTUnwrap(index(CopyProjectToTempDirectory.self)))
    }

    // Every command that uses the mutated project locks it once it knows where it is, and before it reads, removes,
    // copies, builds or tests anything there: a run, a resumed run, mutate-without-running and run-without-mutating.
    func test_lockMutatedProject_comesBeforeAnythingIsReadRemovedCopiedOrTested() throws {
        let commands: [Run.Options] = [
            .make(),
            .make(resumeURL: URL(fileURLWithPath: "/logs")),
            .make(createTestPlan: true),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan")),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), resumeURL: URL(fileURLWithPath: "/logs")),
            .make(mutant: MutantReference(path: "Bar.swift", line: 12)),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), mutant: MutantReference(path: "B", line: 1)),
        ]
        let users: [MutationStep.Type] = [
            CheckTestPlanCode.self,
            CheckMutantSwitches.self,
            PreviousRunCleanUp.self,
            CopyProjectToTempDirectory.self,
            FingerprintProjectTree.self,
            BuildForTesting.self,
            PerformMutationTesting.self,
        ]

        for options in commands {
            let steps = MutationTestHandler(options: options).steps
            let index = { (step: MutationStep.Type) in steps.firstIndex { type(of: $0) == step } }
            let locking = try XCTUnwrap(index(LockMutatedProject.self), "\(options)")
            let naming = try XCTUnwrap(
                index(CreateMutatedProjectDirectoryURL.self) ?? index(LoadMuterTestPlan.self),
                "\(options)"
            )
            XCTAssertLessThan(naming, locking, "it locks the folder the run uses")
            for user in users {
                guard let using = index(user) else { continue }
                XCTAssertLessThan(locking, using, "\(user)")
            }
        }
    }

    // A run started while another of the same project is testing is refused before it removes the other's copy or
    // clones, and the first keeps its lock until its work has ended.
    func test_aSecondRunOfAProject_isRefusedBeforeItRemovesAnything() async throws {
        current.mutatedProjectLocker = MutatedProjectLock.Locker()
        let project = URL(fileURLWithPath: try makeTemporaryDirectory()).appendingPathComponent("x")
        let steps: () -> [MutationStep] = {
            [CreateMutatedProjectDirectoryURL(), LockMutatedProject(), PreviousRunCleanUp()]
        }
        let state = { () -> MutationTestState in
            let state = MutationTestState()
            state.projectDirectoryURL = project
            return state
        }
        let first = state()
        try await MutationTestHandler(steps: steps(), state: first).run()
        // As if the first run had copied the project.
        fileManager.fileExistsToReturn = [true]
        let firstRunsCalls = fileManager.methodCalls.count
        let firstRunsPaths = fileManager.paths.count
        let firstRunsListings = fileManager.contentsOfDirectoryAtPath.count
        let second = state()

        await AssertThrowsError(try await MutationTestHandler(steps: steps(), state: second).run()) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: project.path + "_mutated", process: getpid())
            )
        }
        let secondRunsCalls = fileManager.methodCalls.dropFirst(firstRunsCalls)
        XCTAssertFalse(secondRunsCalls.contains("fileExists(atPath:)"), "\(secondRunsCalls)")
        // The refused run lists and removes only its own log folder, which it kept nothing in.
        XCTAssertEqual(
            Array(fileManager.contentsOfDirectoryAtPath.dropFirst(firstRunsListings)),
            [second.loggingDirectory]
        )
        let secondRunsPaths = fileManager.paths.dropFirst(firstRunsPaths)
        let logsRoot = (second.loggingDirectory as NSString).deletingLastPathComponent
        XCTAssertTrue(
            secondRunsPaths.allSatisfy { $0 == second.loggingDirectory || $0 == logsRoot },
            "\(secondRunsPaths)"
        )

        first.mutatedProjectLock?.release()
        try await MutationTestHandler(steps: steps(), state: state()).run()
        XCTAssertTrue(fileManager.paths.contains(project.path + "_mutated"), "\(fileManager.paths)")
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
        let state = { () -> MutationTestState in
            let state = MutationTestState()
            state.projectDirectoryURL = project
            state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", keepLogFolders: 2)
            return state
        }
        let other = try MutatedProjectLock.Locker().lock(URL(fileURLWithPath: project.path + "_mutated"))
        let locked = MutationTestHandler(steps: steps([]), state: state())
        let refused = MutationTestHandler(steps: steps([RefusingStep()]), state: state())

        await AssertThrowsError(try await locked.run()) { XCTAssertTrue($0 is MutatedProjectLockError, "\($0)") }
        await AssertThrowsError(try await refused.run()) { XCTAssertTrue($0 is ResumeRefused, "\($0)") }
        XCTAssertEqual(pruned.value, 0)

        other.release()
        try await MutationTestHandler(steps: steps([]), state: state()).run()
        XCTAssertEqual(pruned.value, 1)
    }

    // A test plan's run is refused before it reads anything under the mutated project's path, which another run may
    // be rewriting. Checking the plan against the project reads only the project, although the copy was edited.
    func test_aRunOfATestPlan_whileAnotherRunUsesItsMutatedProject_readsNothingThere() async throws {
        current.mutatedProjectLocker = MutatedProjectLock.Locker()
        let root = URL(fileURLWithPath: try makeTemporaryDirectory())
        let mutatedProject = root.appendingPathComponent("x_mutated")
        let project = root.appendingPathComponent("x")
        let source = "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n"
        try write(source, to: project.appendingPathComponent("Sources/Check.swift"))
        try write("edited by hand", to: mutatedProject.appendingPathComponent("Sources/Check.swift"))
        let other = try MutatedProjectLock.Locker().lock(mutatedProject)
        let mapping = try XCTUnwrap(
            generateSchemataMappings(
                for: SourceCodeInfo(
                    path: mutatedProject.path + "/Sources/Check.swift",
                    code: Parser.parse(source: source)
                )
            ).first
        )
        let files = ["Sources/Check.swift": FileDigest.sha256(of: Data(source.utf8))]
        let sources = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: [],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        fileManager.fileContentsToReturn = MuterTestPlan.make(
            mutatedProjectPath: mutatedProject.path,
            sources: sources,
            mappings: [mapping]
        ).toData(under: project)
        let listed = Locked<[URL]>([])
        current.listProjectFiles = { directory in
            listed.change { $0.append(directory) }
            return ["Sources/Check.swift"]
        }
        let state = MutationTestState()
        state.projectDirectoryURL = project
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let steps: [MutationStep] = [
            LoadMuterTestPlan(), CheckTestPlanSources(), LockMutatedProject(), CheckTestPlanCode(),
        ]

        await AssertThrowsError(try await MutationTestHandler(steps: steps, state: state).run()) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: getpid())
            )
        }
        XCTAssertEqual(fileManager.contentsAtPath, ["/project/muter-mappings.json"])
        XCTAssertEqual(listed.value, [project])
        withExtendedLifetime(other) {}
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func test_steps_whenSkipsCoverage() {
        sut = MutationTestHandler(options: .make(skipCoverage: true))

        assertStepsDoesNotContain(sut.steps, DiscoverProjectCoverage.self)
    }

    func test_steps_whenSkipUpdateCheck() {
        sut = MutationTestHandler(options: .make(skipUpdateCheck: true))

        assertStepsDoesNotContain(sut.steps, UpdateCheck.self)
    }

    func test_steps_whenRunWithouMutating() throws {
        fileManager.fileContentsToReturn = MuterTestPlan.make()
            .toData(under: URL(fileURLWithPath: "/path/to/project"))

        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan")
            )
        )

        XCTAssertEqual(sut.steps.count, 12)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        // It reads only the project, so a stale plan is refused before another run's copy is waited on.
        XCTAssertTypeEqual(sut.steps[safe: 3], CheckTestPlanSources.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CheckTestPlanCode.self)
        // The plan's code may have been edited by hand since it was made.
        XCTAssertTypeEqual(sut.steps[safe: 6], CheckMutantSwitches.self)
        // After the lock, in the copy as it is tested, which the results file records.
        XCTAssertTypeEqual(sut.steps[safe: 7], FingerprintProjectTree.self)
        // Once the plan's code and copy can no longer refuse the run.
        XCTAssertTypeEqual(sut.steps[safe: 8], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], ProjectMappings.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], PerformMutationTesting.self)
    }

    func test_steps_whenRunWithoutMutating_resumes() throws {
        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan"),
                resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")
            )
        )

        XCTAssertEqual(sut.steps.count, 13)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], CheckTestPlanSources.self)
        // After the plan, which it compares, and before the lock, as in a run's: a results file another session still
        // writes is refused for that alone.
        XCTAssertTypeEqual(sut.steps[safe: 4], LoadResumeState.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], LockMutatedProject.self)
        // Compares the copy with the one the last session tested.
        XCTAssertTypeEqual(sut.steps[safe: 8], FingerprintProjectTree.self)
        // A changed copy refuses the resume, before any folder is removed.
        XCTAssertTypeEqual(sut.steps[safe: 9], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 12], PerformMutationTesting.self)
    }

    // The copy gets only that mutant's switch, and the rest of the run is a whole run's, but for pruning log folders:
    // a short probe, the run most likely to go alongside another, never removes theirs.
    func test_steps_whenRunningOneMutant() {
        let whole = MutationTestHandler(options: .make(skipCoverage: true)).steps.map { "\(type(of: $0))" }
            .filter { $0 != "PruneLogFolders" }
        sut = MutationTestHandler(options: .make(skipCoverage: true, mutant: MutantReference(path: "B", line: 1)))

        var expected = whole
        expected.insert("SelectMutant", at: whole.firstIndex(of: "ApplySchemata") ?? 0)
        XCTAssertEqual(sut.steps.map { "\(type(of: $0))" }, expected)
        let discovering = whole.firstIndex(of: "DiscoverMutationPoints") ?? 0
        XCTAssertEqual(expected.firstIndex(of: "SelectMutant"), discovering + 1)
    }

    // Right after the plan is read, so its checks look only at the mutant's file, and before the copy is locked: it
    // reads only the plan.
    func test_steps_whenRunWithoutMutating_testsOneMutant() {
        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan"),
                mutant: MutantReference(path: "Bar.swift", line: 12)
            )
        )

        XCTAssertEqual(sut.steps.count, 12)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], SelectMutant.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], CheckTestPlanSources.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], LockMutatedProject.self)
        // No pruning: a run of one mutant never removes other runs' log folders.
        XCTAssertTypeEqual(sut.steps[safe: 6], CheckTestPlanCode.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], PerformMutationTesting.self)
    }

    func test_steps_withoutMutant_haveNoSelectMutant() {
        let commands: [Run.Options] = [
            .make(),
            .make(createTestPlan: true),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan")),
        ]
        for options in commands {
            assertStepsDoesNotContain(MutationTestHandler(options: options).steps, SelectMutant.self)
        }
    }

    func test_steps_whenMutateWithoutRunning() {
        sut = MutationTestHandler(
            options: .make(
                createTestPlan: true
            )
        )

        XCTAssertEqual(sut.steps.count, 14)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CopyProjectToTempDirectory.self)
        // Before anything is rewritten: the plan records the project's files as they were.
        XCTAssertTypeEqual(sut.steps[safe: 6], FingerprintProjectTree.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], PruneLogFolders.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], ApplySchemata.self)
        // No plan is made whose code lacks a mutant's switch.
        XCTAssertTypeEqual(sut.steps[safe: 12], CheckMutantSwitches.self)
        XCTAssertTypeEqual(sut.steps[safe: 13], CreateMuterTestPlan.self)
    }

    // After every step that can refuse the run or find nothing to test, so a run that ends that way removes nothing
    // and never counts as one of the runs kept, and before the build and the test runs, so the space is freed before
    // most logs are written. A run of one mutant has no pruning at all.
    func test_pruneLogFolders_comesOnceNothingCanRefuseTheRun_andBeforeAnythingIsBuilt() throws {
        let commands: [Run.Options] = [
            .make(),
            .make(since: "main"),
            .make(skipCoverage: true),
            .make(shard: Shard(index: 2, count: 4)),
            .make(resumeURL: URL(fileURLWithPath: "/logs")),
            .make(reuseURL: URL(fileURLWithPath: "/logs")),
            .make(createTestPlan: true),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan")),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), resumeURL: URL(fileURLWithPath: "/logs")),
        ]
        // Each can refuse the run (`ResumeRefused`, `TestPlanRefused`, a lock in use), or find nothing to test
        // (`NothingToMutate`, `EmptyShard`).
        let before: [MutationStep.Type] = [
            LoadConfiguration.self, SelectChangedCode.self, LoadResumeState.self, LoadMuterTestPlan.self,
            CheckTestPlanSources.self, LockMutatedProject.self, CheckTestPlanCode.self, FingerprintProjectTree.self,
            ListChangedSources.self, DiscoverSourceFiles.self, DiscoverMutationPoints.self,
        ]
        let after: [MutationStep.Type] = [
            ApplySchemata.self, BuildForTesting.self, PerformMutationTesting.self, CreateMuterTestPlan.self,
        ]

        for options in commands {
            let steps = MutationTestHandler(options: options).steps
            let index = { (step: MutationStep.Type) in steps.firstIndex { type(of: $0) == step } }
            let pruning = try XCTUnwrap(index(PruneLogFolders.self), "\(options)")
            for step in before {
                guard let earlier = index(step) else { continue }
                XCTAssertLessThan(earlier, pruning, "\(step), \(options)")
            }
            for step in after {
                guard let later = index(step) else { continue }
                XCTAssertLessThan(pruning, later, "\(step), \(options)")
            }
        }
        for options: Run.Options in [
            .make(mutant: MutantReference(path: "Bar.swift", line: 12)),
            .make(testPlanURL: URL(fileURLWithPath: "/path/to/testplan"), mutant: MutantReference(path: "B", line: 1)),
        ] {
            assertStepsDoesNotContain(MutationTestHandler(options: options).steps, PruneLogFolders.self)
        }
    }

    private func assertStepsDoesNotContain(
        _ steps: [MutationStep],
        _ step: MutationStep.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            steps.contains { type(of: $0) == step },
            file: file,
            line: line
        )
    }
}

/// A step that refuses a resume, as `LoadResumeState` and `FingerprintProjectTree` do.
private final class RefusingStep: MutationStep {
    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
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

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        loggingDirectories.append(state.loggingDirectory)
        return []
    }
}
