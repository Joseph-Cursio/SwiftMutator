@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class MutationTestHandlerTests: MuterTestCase {
    let stepSpy1 = MutationStepSpy()
    let stepSpy2 = MutationStepSpy()
    let stepSpy3 = MutationStepSpy()
    let state = MutationTestState()

    lazy var sut = MutationTestHandler(
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
            XCTAssertIdentical(self.stepSpy1.states.first, expectedState)
            XCTAssertIdentical(self.stepSpy2.states.first, expectedState)
            XCTAssertIdentical(self.stepSpy3.states.first, expectedState)
        }

        let assertThatReturnsSuccess = {
            XCTAssertEqual(expectedState.mutatedProjectDirectoryURL, URL(string: "/lol/son")!)
            XCTAssertEqual(expectedState.projectDirectoryURL, URL(string: "/lol")!)
        }

        assertThatRunsAllItsSteps()
        assertThatAllStepsShareTheState()
        assertThatReturnsSuccess()
    }

    func givenThereAreNoFailuresInAnyOfItSteps() {
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
            XCTAssertIdentical(self.stepSpy1.states.first, self.state)
            XCTAssertIdentical(self.stepSpy2.states.first, self.state)
            XCTAssertTrue(self.stepSpy3.states.isEmpty)
        }

        assertThatNoStepRunsAfterTheFailingOne()
        assertThatNoLaterStepGetsTheState()
    }

    func givenThereIsAFailureInOneOfItsSteps() {
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
}
