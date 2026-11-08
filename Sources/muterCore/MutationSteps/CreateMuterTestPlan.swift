import Foundation

/// Writes the test plan, `muter-mappings.json`, into the project folder, with its paths relative to it
/// (`TestPlanFile`), so the project and its copy can move together. The plan records the operators and files its
/// mutants were chosen by, the project's files as `FingerprintProjectTree` found them before anything was rewritten,
/// which a run of the plan checks the project against, and the SHA-256 of each file with mutants as the copy now holds
/// it. For a file with mutants that is a symbolic link in the project, whose file the project's files record only by
/// where it points, it also records the SHA-256 of what the link's file holds, and it records the mutants of code no
/// test ran, which a run of the plan compares with `--baseline`'s file. It runs once the copy is locked and its
/// switches checked.
struct CreateMuterTestPlan: MutationStep {
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.writeFile)
    private var writeFile: WriteFile
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        let testPlan = MuterTestPlan(
            mutatedProjectURL: state.mutatedProjectDirectoryURL,
            projectCoverage: state.projectCoverage,
            scope: TestPlanScope(operators: state.mutationOperatorList, filesToMutate: state.filesToMutate),
            sources: state.projectTree,
            mutatedFiles: mutatedFiles(in: state),
            linkedFiles: linkedFiles(in: state),
            mappings: state.mutationMapping,
            mutantsNotCovered: state.uncoveredMutants
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

    /// The SHA-256 of each file with mutants, as the copy holds it, by its path relative to the copy. A file that
    /// can't be read is left out.
    private func mutatedFiles(in state: AnyMutationTestState) -> [String: String] {
        var files: [String: String] = [:]
        for mapping in state.mutationMapping {
            guard let contents = fileManager.contents(atPath: mapping.filePath) else { continue }
            files[RepoRelativePath.of(mapping.filePath, under: state.mutatedProjectDirectoryURL)] =
                FileDigest.sha256(of: contents)
        }
        return files
    }

    /// The SHA-256 of what each file with mutants that is a symbolic link in the project holds, read through the link,
    /// by its path relative to the project; nil when none is. A file that can't be read is left out.
    private func linkedFiles(in state: AnyMutationTestState) -> [String: String]? {
        guard let recorded = state.projectTree?.files else { return nil }
        var files: [String: String] = [:]
        for mapping in state.mutationMapping {
            let path = RepoRelativePath.of(mapping.filePath, under: state.mutatedProjectDirectoryURL)
            guard recorded[path]?.hasPrefix(ProjectTree.linkPrefix) == true,
                  let digest = FileDigest.sha256(of: state.projectDirectoryURL.appendingPathComponent(path))
            else { continue }
            files[path] = digest
        }
        return files.isEmpty ? nil : files
    }
}
