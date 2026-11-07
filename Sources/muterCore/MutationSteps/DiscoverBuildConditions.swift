import Foundation

/// Works out what the build compiles with, for discovery to leave out the mutants of code an `#if` keeps out of it.
/// Coverage can't say so for a whole declaration in an `#if`, of which it has no record, nor in a run without coverage.
struct DiscoverBuildConditions: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.process)
    private var process: ProcessFactory

    func run(
        with state: AnyMutationTestState
    ) async throws -> [MutationTestState.Change] {
        let configuration = state.muterConfiguration
        guard configuration.buildSystem != .unknown else {
            return []
        }

        // As the coverage run and the tests are: a relative `executable` or `--package-path` is relative to it.
        let rootPath = state.mutatedProjectDirectoryURL.path
        let currentDirectoryPath = fileManager.currentDirectoryPath
        fileManager.changeCurrentDirectoryPath(rootPath)
        defer {
            fileManager.changeCurrentDirectoryPath(currentDirectoryPath)
        }

        let conditions = configuration.buildSystem == .swift
            ? await SwiftPackageBuildConditions.conditions(
                inProjectAt: rootPath,
                testedBy: configuration,
                process: process,
                fileManager: fileManager
            )
            : await XcodeBuildConditions.conditions(
                inProjectAt: rootPath,
                testedBy: configuration,
                process: process,
                fileManager: fileManager
            )

        switch conditions {
        case let .success(conditions):
            return [.buildConditionsDiscovered(conditions)]
        case let .failure(failure):
            // A command that stopping the run killed reads as failed, and no notice is due.
            try Task.checkCancellation()
            events.send(.buildConditionsUnavailable(reason: failure.reason))
            return []
        }
    }
}
