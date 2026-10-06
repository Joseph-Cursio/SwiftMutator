@testable import muterCore
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

        XCTAssertEqual(sut.steps.count, 12)

        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], CopyProjectToTempDirectory.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], GenerateSwapFilePaths.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], ApplySchemata.self)
        XCTAssertTypeEqual(sut.steps[safe: 10], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 11], PerformMutationTesting.self)
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

        XCTAssertEqual(sut.steps.count, 6)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], LoadMuterTestPlan.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], BuildForTesting.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], ProjectMappings.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], PerformMutationTesting.self)
    }

    func test_steps_whenMutateWithoutRunning() {
        sut = MutationTestHandler(
            options: .make(
                createTestPlan: true
            )
        )

        XCTAssertEqual(sut.steps.count, 10)
        XCTAssertTypeEqual(sut.steps[safe: 0], UpdateCheck.self)
        XCTAssertTypeEqual(sut.steps[safe: 1], LoadConfiguration.self)
        XCTAssertTypeEqual(sut.steps[safe: 2], CreateMutatedProjectDirectoryURL.self)
        XCTAssertTypeEqual(sut.steps[safe: 3], PreviousRunCleanUp.self)
        XCTAssertTypeEqual(sut.steps[safe: 4], CopyProjectToTempDirectory.self)
        XCTAssertTypeEqual(sut.steps[safe: 5], DiscoverProjectCoverage.self)
        XCTAssertTypeEqual(sut.steps[safe: 6], DiscoverSourceFiles.self)
        XCTAssertTypeEqual(sut.steps[safe: 7], DiscoverMutationPoints.self)
        XCTAssertTypeEqual(sut.steps[safe: 8], ApplySchemata.self)
        XCTAssertTypeEqual(sut.steps[safe: 9], CreateMuterTestPlan.self)
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
