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

        let assertThatSharesTheSameStateAcrossAllOfTheSteps = {
            XCTAssertTrue(self.stepSpy1.states.first === expectedState)
            XCTAssertTrue(self.stepSpy2.states.first === expectedState)
            XCTAssertTrue(self.stepSpy3.states.first === expectedState)
        }

        let assertThatReturnsSuccess = {
            XCTAssertEqual(expectedState.mutatedProjectDirectoryURL, URL(string: "/lol/son")!)
            XCTAssertEqual(expectedState.projectDirectoryURL, URL(string: "/lol")!)
        }

        assertThatRunsAllItsSteps()
        assertThatSharesTheSameStateAcrossAllOfTheSteps()
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

        let assertThatWontRunAnySubsequentStepsAfterTheFailingStep = {
            XCTAssertEqual(self.stepSpy1.methodCalls, ["run(with:)"])
            XCTAssertEqual(self.stepSpy2.methodCalls, ["run(with:)"])
            XCTAssertTrue(self.stepSpy3.methodCalls.isEmpty)
        }

        let assertThatWontShareTheStateWithAnySubsequentStepsAfterTheFailingStep = {
            XCTAssertTrue(self.stepSpy1.states.first === self.state)
            XCTAssertTrue(self.stepSpy2.states.first === self.state)
            XCTAssertTrue(self.stepSpy3.states.isEmpty)
        }

        assertThatWontRunAnySubsequentStepsAfterTheFailingStep()
        assertThatWontShareTheStateWithAnySubsequentStepsAfterTheFailingStep()
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

        let result = await Task { [sut] in try await sut.run() }.result

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

        let loggingDirectory = try XCTUnwrap(fileManager.paths.first)
        XCTAssertTrue(loggingDirectory.hasPrefix("/project_muter_logs/"), loggingDirectory)
        XCTAssertEqual(firstStep.loggingDirectories, [loggingDirectory])
        XCTAssertEqual(state.loggingDirectory, loggingDirectory)
    }

    func test_allSteps() {
        sut = MutationTestHandler(options: .make())

        XCTAssertEqual(sut.steps.count, 13)

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
        XCTAssertTypeEqual(sut.steps[safe: 10], ApplySchemata.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 12], PerformMutationTesting.self)
    }

    func test_steps_whenResuming() {
        sut = MutationTestHandler(options: .make(resumeURL: URL(fileURLWithPath: "/logs/results.jsonl")))

        XCTAssertEqual(sut.steps.count, 14)

        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadResumeState.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], CopyProjectToTempDirectory.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], FingerprintProjectTree.self)
        XCTAssertTypeEqual(sut.steps[safe: 13], PerformMutationTesting.self)
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
        ]
        let users: [MutationStep.Type] = [
            CheckTestPlanCode.self,
            PreviousRunCleanUp.self,
            CopyProjectToTempDirectory.self,
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

        await AssertThrowsError(try await MutationTestHandler(steps: steps(), state: state()).run()) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: project.path + "_mutated", process: getpid())
            )
        }
        let secondRunsCalls = fileManager.methodCalls.dropFirst(firstRunsCalls)
        XCTAssertFalse(secondRunsCalls.contains("fileExists(atPath:)"), "\(secondRunsCalls)")
        XCTAssertFalse(secondRunsCalls.contains("removeItem(atPath:)"), "\(secondRunsCalls)")
        XCTAssertFalse(secondRunsCalls.contains("contentsOfDirectory(atPath:)"), "\(secondRunsCalls)")

        first.mutatedProjectLock?.release()
        try await MutationTestHandler(steps: steps(), state: state()).run()
        XCTAssertTrue(fileManager.paths.contains(project.path + "_mutated"), "\(fileManager.paths)")
    }

    // A test plan's run is refused before it reads the mutated project's code, which another run may be rewriting.
    func test_aRunOfATestPlan_whileAnotherRunUsesItsMutatedProject_readsNothingThere() async throws {
        current.mutatedProjectLocker = MutatedProjectLock.Locker()
        let mutatedProject = URL(fileURLWithPath: try makeTemporaryDirectory()).appendingPathComponent("x_mutated")
        let other = try MutatedProjectLock.Locker().lock(mutatedProject)
        let mapping = try XCTUnwrap(
            generateSchemataMappings(
                for: SourceCodeInfo(
                    path: mutatedProject.path + "/Sources/Check.swift",
                    code: Parser.parse(source: "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n")
                )
            ).first
        )
        fileManager.fileContentsToReturn = MuterTestPlan.make(
            mutatedProjectPath: mutatedProject.path,
            mappings: [mapping]
        ).toData
        let state = MutationTestState()
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let steps: [MutationStep] = [LoadMuterTestPlan(), LockMutatedProject(), CheckTestPlanCode()]

        await AssertThrowsError(try await MutationTestHandler(steps: steps, state: state).run()) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: getpid())
            )
        }
        XCTAssertEqual(fileManager.contentsAtPath, ["/project/muter-mappings.json"])
        withExtendedLifetime(other) {}
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
        fileManager.fileContentsToReturn = MuterTestPlan.make().toData

        sut = MutationTestHandler(
            options: .make(
                testPlanURL: URL(fileURLWithPath: "/path/to/testplan")
            )
        )

        XCTAssertEqual(sut.steps.count, 8)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], CheckTestPlanCode.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], ProjectMappings.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], PerformMutationTesting.self)
    }

    func test_steps_whenMutateWithoutRunning() {
        sut = MutationTestHandler(
            options: .make(
                createTestPlan: true
            )
        )

        XCTAssertEqual(sut.steps.count, 11)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], LockMutatedProject.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], CopyProjectToTempDirectory.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], ApplySchemata.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], CreateMuterTestPlan.self)
    }

    private func assertStepsDoesNotContain(
        _ steps: [MutationStep],
        _ step: MutationStep.Type,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            steps.contains { type(of: $0) == step },
            file: file,
            line: line
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
