import Foundation

final class DiscoverProjectCoverage: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.projectCoverage)
    private var projectCoverage: ProjectCoverage

    /// The name the coverage run's output is kept under in the run's log folder.
    static let logFileName = "coverage run.log"

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        guard let coverage = projectCoverage(
            state.muterConfiguration.buildSystem
        )
        else {
            return [.projectCoverage(.null)]
        }

        events.send(.projectCoverageDiscoveryStarted)

        let currentDirectoryPath = fileManager.currentDirectoryPath
        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)

        defer {
            fileManager.changeCurrentDirectoryPath(currentDirectoryPath)
        }

        let result = await coverage.run(with: state.muterConfiguration)
        // Kept as the baseline's output is, even from a stopped run: what it printed can show which test hung.
        let log = coverage.coverageRunOutput.flatMap { fileManager.keepLog($0, named: Self.logFileName, state: state) }
        // Stopping the run kills the coverage run, which then fails, but mutation testing won't go on without it.
        try Task.checkCancellation()

        switch result {
        case let .success(coverage):
            if let failedTests = coverage.testsFailedWithCoverageOn {
                events.send(.projectCoverageTestsFailed(TestsFailedWithCoverage(tests: failedTests, log: log)))
            }
            events.send(.projectCoverageDiscoveryFinished(nil))

            return [.projectCoverage(coverage)]
        case let .failure(error):
            events.send(.projectCoverageDiscoveryFinished(CoverageFailure(reason: error.reason, log: log)))

            return [.projectCoverage(.null)]
        }
    }
}

/// Why coverage couldn't be gathered, and where the coverage run's output is kept, if it is.
struct CoverageFailure: Equatable {
    let reason: String
    let log: String?
}

/// The tests that failed in the coverage run although its coverage was gathered, and where its output is kept, if it
/// is.
struct TestsFailedWithCoverage: Equatable {
    let tests: FailedTestLine.FailedTests
    let log: String?
}
