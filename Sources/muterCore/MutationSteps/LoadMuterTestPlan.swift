import Foundation

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
        try refuseCodeThatCannotReadTheActiveMutantFile(in: testPlan, testedWith: state.muterConfiguration)

        notificationCenter.post(name: .muterMutationTestPlanLoaded, object: nil)

        return [
            .tempDirectoryUrlCreated(URL(fileURLWithPath: testPlan.mutatedProjectPath)),
            .projectCoverage(.init(percent: testPlan.projectCoverage)),
            .mutationMappingsDiscovered(testPlan.mappings),
        ]
    }

    /// Why a `swift test` plan made by an older SwiftMutator is refused, and how to make it again.
    static func codePredatesTheActiveMutantFile(_ mutatedProjectPath: String) -> String {
        """
        The test plan's mutated project, \(mutatedProjectPath), was made by an older SwiftMutator. Its code never \
        reads the file this one names each `swift test` run's mutant in, so every mutant would survive. Make the \
        test plan again with `swift-mutator mutate-without-running`.
        """
    }

    /// A `swift test` run names its mutant in the file `activeMutantFileKey` names, which code made by an older
    /// SwiftMutator never reads. Every file in a plan was made by one SwiftMutator, so the first file that settles
    /// it decides: one naming the key reads the file; one holding a mutant's switch without it predates it. Files
    /// with neither, as a file that couldn't be rewritten, settle nothing. Other test commands still switch each
    /// mutant on through its own variable, which older code reads too.
    private func refuseCodeThatCannotReadTheActiveMutantFile(
        in testPlan: MuterTestPlan,
        testedWith configuration: MuterConfiguration
    ) throws {
        guard configuration.buildSystem == .swift else { return }
        for mapping in testPlan.mappings where !mapping.isEmpty {
            guard let data = fileManager.contents(atPath: mapping.filePath) else { continue }
            let code = String(decoding: data, as: UTF8.self)
            if code.contains(activeMutantFileKey) { return }
            if mapping.mutationSchemata.contains(where: { code.contains("\"\($0.id)\"") }) {
                throw MuterError.literal(reason: Self.codePredatesTheActiveMutantFile(testPlan.mutatedProjectPath))
            }
        }
    }
}
