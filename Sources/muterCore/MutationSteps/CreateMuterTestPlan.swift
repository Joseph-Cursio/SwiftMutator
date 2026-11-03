import Foundation

/// Writes the test plan, `muter-mappings.json`, into the project folder, with its paths relative to it
/// (`TestPlanFile`), so the project and its copy can move together. The plan records the operators and files its
/// mutants were chosen by.
struct CreateMuterTestPlan: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.writeFile)
    private var writeFile: WriteFile

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let testPlan = MuterTestPlan(
            mutatedProjectURL: state.mutatedProjectDirectoryURL,
            projectCoverage: state.projectCoverage,
            scope: TestPlanScope(operators: state.mutationOperatorList, filesToMutate: state.filesToMutate),
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

        let operators = Set(state.mutationOperatorList.map(\.rawValue))
        events.send(
            .testPlanFileCreated(
                TestPlanCreated(
                    path: jsonUrl.path,
                    mutatedProject: RelativePath.from(state.projectDirectoryURL, to: state.mutatedProjectDirectoryURL),
                    mutants: state.mutationMapping.reduce(0) { $0 + $1.mutationSchemata.count },
                    files: state.mutationMapping.count,
                    operators: operators == Set(MutationOperatorList.allOperators.map(\.rawValue))
                        ? nil
                        : operators.sorted()
                )
            )
        )

        return []
    }
}
