import Foundation

final class DiscoverProjectCoverage: MutationStep {
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.projectCoverage)
    private var projectCoverage: ProjectCoverage

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        guard let coverage = projectCoverage(
            state.muterConfiguration.buildSystem
        )
        else {
            return [.projectCoverage(.null)]
        }

        notificationCenter.post(
            name: .projectCoverageDiscoveryStarted,
            object: nil
        )

        let currentDirectoryPath = fileManager.currentDirectoryPath
        fileManager.changeCurrentDirectoryPath(state.mutatedProjectDirectoryURL.path)

        defer {
            fileManager.changeCurrentDirectoryPath(currentDirectoryPath)
        }

        let result = coverage.run(with: state.muterConfiguration)
        // Stopping the run kills the coverage run, which then fails, but mutation testing won't go on without it.
        try Task.checkCancellation()

        switch result {
        case let .success(coverage):
            notificationCenter.post(
                name: .projectCoverageDiscoveryFinished,
                object: true
            )

            return [.projectCoverage(coverage)]
        case .failure:
            notificationCenter.post(
                name: .projectCoverageDiscoveryFinished,
                object: false
            )

            return [.projectCoverage(.null)]
        }
    }
}
