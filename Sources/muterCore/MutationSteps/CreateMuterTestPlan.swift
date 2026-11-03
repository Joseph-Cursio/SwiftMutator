import Foundation

/// Writes the test plan, `muter-mappings.json`, into the project folder, with its paths relative to it
/// (`TestPlanFile`), so the project and its copy can move together.
struct CreateMuterTestPlan: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.writeFile)
    private var writeFile: WriteFile

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let testPlan = MuterTestPlan(
            mutatedProjectURL: state.mutatedProjectDirectoryURL,
            projectCoverage: state.projectCoverage,
            mappings: state.mutationMapping
        )

        let json = try TestPlanCoding.encode(testPlan, under: state.projectDirectoryURL)

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
