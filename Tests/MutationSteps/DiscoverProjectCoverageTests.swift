@testable import muterCore
import TestingExtensions
import XCTest

final class DiscoverProjectCoverageTests: MuterTestCase {
    private let state = MutationTestState()

    private lazy var sut = DiscoverProjectCoverage()

    func test_whenStepStarts_shouldFireNotification() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["arg0", "arg1"]
        )

        let expectation = expectation(
            forNotification: .projectCoverageDiscoveryStarted,
            object: nil,
            notificationCenter: notificationCenter
        )

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

    func test_whenStepFails_thenPostNotification() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: []
        )

        process.stdoutToBeReturned = ""

        let expectation = expectation(
            forNotification: .projectCoverageDiscoveryFinished,
            object: false,
            notificationCenter: notificationCenter
        )

        _ = try await sut.run(with: state)

        await fulfillment(of: [expectation], timeout: 2)
    }

    // Stopping the run kills the coverage run, which then fails. Saying coverage couldn't be gathered, and that
    // mutation testing goes on anyway, would be wrong twice.
    func test_aCancelledCoverageRun_isNotReportedAsAFailure() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: []
        )
        let coverage = CoverageStub {
            withUnsafeCurrentTask { $0?.cancel() }
            return .failure(.build)
        }
        current.projectCoverage = { _ in coverage }
        let finished = expectation(
            forNotification: .projectCoverageDiscoveryFinished,
            object: nil,
            notificationCenter: notificationCenter
        )
        finished.isInverted = true

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // It would have been posted before the run returned.
        await fulfillment(of: [finished], timeout: 0.1)
    }
}

/// A coverage run that ends however `run` says, after doing whatever it does.
private final class CoverageStub: BuildSystemCoverage {
    @Dependency(\.process)
    var process: ProcessFactory

    private let result: () -> Result<Coverage, CoverageError>

    init(_ result: @escaping () -> Result<Coverage, CoverageError>) {
        self.result = result
    }

    func run(with configuration: MuterConfiguration) -> Result<Coverage, CoverageError> {
        result()
    }

    func buildDirectory(_ configuration: MuterConfiguration) -> String? {
        nil
    }
}
