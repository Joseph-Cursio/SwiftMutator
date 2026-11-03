import Foundation

struct CreateMuterTestPlan: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.writeFile)
    private var writeFile: WriteFile

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let testPlan = MuterTestPlan(
            mutatedProjectPath: state.mutatedProjectDirectoryURL.path,
            projectCoverage: state.projectCoverage.percent,
            mappings: state.mutationMapping
        )

        let json = try TestPlanCoding.encode(testPlan)

        let jsonUrl = state.projectDirectoryURL
            .appendingPathComponent("muter-mappings")
            .appendingPathExtension("json")

        try writeFile(
            json,
            jsonUrl.path
        )

        events.send(.testPlanFileCreated(path: jsonUrl.path))

        return []
    }
}
