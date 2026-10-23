import Foundation

/// Reads the test plan, and nothing in the mutated project it names: until `LockMutatedProject` has locked that,
/// another run of the project could be removing or rewriting it. `CheckTestPlanCode` reads its code once it's locked.
struct LoadMuterTestPlan: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let testPlanPath = state.runOptions.testPlanURL?.path else {
            throw MuterError.literal(reason: "Could not load the test plan")
        }

        guard let testPlanData = fileManager.contents(atPath: testPlanPath) else {
            throw MuterError.literal(reason: "Could not load the test plan at path: \(testPlanPath)")
        }

        let testPlan = try JSONDecoder().decode(MuterTestPlan.self, from: testPlanData)

        notificationCenter.post(name: .muterMutationTestPlanLoaded, object: nil)

        return [
            .tempDirectoryUrlCreated(URL(fileURLWithPath: testPlan.mutatedProjectPath)),
            .projectCoverage(.init(percent: testPlan.projectCoverage)),
            .mutationMappingsDiscovered(testPlan.mappings),
        ]
    }
}
