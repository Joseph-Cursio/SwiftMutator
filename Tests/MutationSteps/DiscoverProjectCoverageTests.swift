@testable import muterCore
import TestingExtensions
import XCTest

final class DiscoverProjectCoverageTests: MuterTestCase {
    private let state = MutationTestState()

    private lazy var sut = DiscoverProjectCoverage()

    func test_whenStepStarts_shouldSendAnEvent() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["arg0", "arg1"]
        )

        let expectation = expectation(forEvent: .projectCoverageDiscoveryStarted)

        _ = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
    }

    func test_shouldReturnNullForUnknownBuildSytem() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/unknown",
            arguments: []
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(
            result,
            [.projectCoverage(.null)]
        )
    }

    func test_shouldChangeCurrentPath() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: []
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.methodCalls,
            [
                "changeCurrentDirectoryPath(_:)",
                "changeCurrentDirectoryPath(_:)",
            ]
        )
    }

    func test_whenStepFails_thenSendsAnEvent() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: []
        )

        process.commandResult = { _ in CommandResult(status: 65, endedBySignal: false, output: "", errors: "") }

        // Why it failed, for the message that says so. This state has no log folder to keep the output in.
        let reason = "the coverage run failed (exit status 65) without naming a failed test or an error"
        let expectation = expectation(forEvent: .projectCoverageDiscoveryFinished) {
            ($0.object as? CoverageFailure) == CoverageFailure(reason: reason, log: nil)
        }

        _ = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
    }

    func test_whenStepSucceeds_thenSendsAnEventWithNoReason() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        current.projectCoverage = { _ in CoverageStub { .success(.make(percent: 80)) } }

        let expectation = expectation(forEvent: .projectCoverageDiscoveryFinished) { $0.object == nil }

        let result = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, [.projectCoverage(.make(percent: 80))])
    }

    // As the baseline's output is kept, whether the coverage run succeeds or fails.
    func test_theCoverageRunsOutput_isKeptInTheLogFolder() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        state.loggingDirectory = "/logs"
        let results: [Result<Coverage, CoverageError>] = [.success(.make(percent: 80)), .failure(.noBuildDirectory)]

        for result in results {
            current.projectCoverage = { _ in CoverageStub(output: "Test run passed\n") { result } }
            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(fileManager.paths, ["/logs/coverage run.log", "/logs/coverage run.log"])
        XCTAssertEqual(fileManager.contents, Data("Test run passed\n".utf8))
    }

    // A state that bypasses the handler has no log folder, and a run that couldn't be started printed nothing.
    func test_withoutALogFolder_orACoverageRun_nothingIsKept() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        current.projectCoverage = { _ in CoverageStub(output: "Test run passed\n") { .success(.make()) } }
        _ = try await sut.run(with: state)

        state.loggingDirectory = "/logs"
        current.projectCoverage = { _ in CoverageStub(output: nil) { .failure(.couldNotRun("/path/to/swift")) } }
        _ = try await sut.run(with: state)

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
    }

    // So the message that says it failed can say where to look.
    func test_whenStepFails_whereTheOutputIsKept_isPosted() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        state.loggingDirectory = "/logs"
        current.projectCoverage = { _ in
            CoverageStub(output: "error: Build failed\n") { .failure(.runFailed(status: 1, error: nil)) }
        }

        let expectation = expectation(forEvent: .projectCoverageDiscoveryFinished) {
            ($0.object as? CoverageFailure) == CoverageFailure(
                reason: CoverageError.runFailed(status: 1, error: nil).reason,
                log: "/logs/coverage run.log"
            )
        }

        _ = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
    }

    // A coverage run stopped at `buildTimeout` is a failure like any other: mutation testing goes on without coverage,
    // and the message says why and where the output is.
    func test_aCoverageRunPastItsTimeLimit_goesOnWithoutCoverage() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [], buildTimeout: 900)
        state.loggingDirectory = "/logs"
        current.projectCoverage = { _ in
            CoverageStub(output: "◇ Test hangs() started.\n") { .failure(.timedOut(after: 900)) }
        }

        let expectation = expectation(forEvent: .projectCoverageDiscoveryFinished) {
            ($0.object as? CoverageFailure) == CoverageFailure(
                reason: "the tests with coverage on didn't end within 900 s (buildTimeout), "
                    + "so SwiftMutator stopped them",
                log: "/logs/coverage run.log"
            )
        }

        let result = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, [.projectCoverage(.null)])
        XCTAssertEqual(fileManager.contents, Data("◇ Test hangs() started.\n".utf8))
    }

    // Coverage gathered although tests failed is sent with them, for the warning that names them.
    func test_testsThatFailedWithCoverageOn_arePosted_withWhereTheOutputIsKept() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        state.loggingDirectory = "/logs"
        let failedTests = FailedTestLine.FailedTests(
            tests: [.init(name: "sum()", location: "SumTests.swift:12:5")],
            count: 1,
            firstLine: nil
        )
        current.projectCoverage = { _ in
            CoverageStub(output: "✘ Test sum() recorded an issue\n") {
                .success(.make(percent: 80, testsFailedWithCoverageOn: failedTests))
            }
        }

        let expectation = expectation(forEvent: .projectCoverageTestsFailed) {
            ($0.object as? TestsFailedWithCoverage)
                == TestsFailedWithCoverage(tests: failedTests, log: "/logs/coverage run.log")
        }

        let result = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, [.projectCoverage(.make(percent: 80, testsFailedWithCoverageOn: failedTests))])
    }

    func test_whenEveryTestPassed_noFailedTestIsSent() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        current.projectCoverage = { _ in CoverageStub { .success(.make(percent: 80)) } }
        let failed = expectation(forEvent: .projectCoverageTestsFailed)
        failed.isInverted = true

        _ = try await sut.run(with: state)

        // It would have been sent before the run returned.
        await fulfillment(of: [failed], timeout: 0.1)
    }

    // Stopping the run kills the coverage run, which then fails. Saying coverage couldn't be gathered, and that
    // mutation testing goes on anyway, would be wrong twice.
    func test_aCancelledCoverageRun_isNotReportedAsAFailure() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: []
        )
        current.projectCoverage = { _ in
            CoverageStub {
                withUnsafeCurrentTask { $0?.cancel() }
                return .failure(.build)
            }
        }
        let finished = expectation(forEvent: .projectCoverageDiscoveryFinished)
        finished.isInverted = true

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // It would have been sent before the run returned.
        await fulfillment(of: [finished], timeout: 0.1)
    }

    // Without `buildTimeout`, a stop is what ends a coverage run that hangs, and what it printed can show which test
    // hung, so that is still kept.
    func test_aCancelledCoverageRun_keepsWhatItPrinted() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/path/to/swift", arguments: [])
        state.loggingDirectory = "/logs"
        current.projectCoverage = { _ in
            CoverageStub(output: "◇ Test hangs() started.\n") {
                withUnsafeCurrentTask { $0?.cancel() }
                return .failure(.runFailed(status: 1, error: nil))
            }
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(fileManager.paths, ["/logs/coverage run.log"])
        XCTAssertEqual(fileManager.contents, Data("◇ Test hangs() started.\n".utf8))
    }
}

/// A coverage run that ends however `run` says, after doing whatever it does, having printed `output`.
private final class CoverageStub: BuildSystemCoverage {
    @Dependency(\.process)
    var process: ProcessFactory
    let coverageRunOutput: String?

    private let result: () -> Result<Coverage, CoverageError>

    init(output: String? = nil, _ result: @escaping () -> Result<Coverage, CoverageError>) {
        coverageRunOutput = output
        self.result = result
    }

    func run(with configuration: MuterConfiguration) -> Result<Coverage, CoverageError> {
        result()
    }

    func buildDirectory(_ configuration: MuterConfiguration) -> String? {
        nil
    }
}
