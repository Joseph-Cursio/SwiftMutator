import Foundation

struct ProjectMappings: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        events.send(.mutationsDiscoveryFinished(state.mutationMapping))

        return []
    }
}
