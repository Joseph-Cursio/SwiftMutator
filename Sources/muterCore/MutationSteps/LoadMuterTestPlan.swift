import Foundation

/// Reads the test plan, and nothing in the mutated project it names: until `LockMutatedProject` has locked that,
/// another run of the project could be removing or rewriting it. `CheckTestPlanCode` reads its code once it's locked.
/// The plan's relative paths are resolved under the folder the run is in, which is the project's: the plan names its
/// copy relative to the folder it was made in.
struct LoadMuterTestPlan: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.events)
    private var events: RunEvents

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let testPlanPath = state.runOptions.testPlanURL?.path else {
            throw MuterError.literal(reason: "Could not load the test plan")
        }

        guard let testPlanData = fileManager.contents(atPath: testPlanPath) else {
            throw MuterError.literal(reason: "Could not load the test plan at path: \(testPlanPath)")
        }

        let testPlan = try TestPlanCoding.read(testPlanData, path: testPlanPath, under: state.projectDirectoryURL)

        events.send(.muterMutationTestPlanLoaded)

        return [
            .tempDirectoryUrlCreated(testPlan.mutatedProjectURL),
            .projectCoverage(testPlan.projectCoverage),
            .mutationMappingsDiscovered(testPlan.mappings),
            .testPlanLoaded(
                LoadedTestPlan(
                    path: testPlanPath,
                    sha256: FileDigest.sha256(of: testPlanData),
                    formatVersion: testPlan.formatVersion,
                    swiftMutatorVersion: testPlan.swiftMutatorVersion,
                    scope: testPlan.scope,
                    sources: testPlan.sources
                )
            ),
        ]
    }
}
