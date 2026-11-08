import Foundation

/// Loads `--baseline`'s file as the run starts, so a typo, a missing file or one of another scope doesn't wait for a
/// long run to end: refused (`BaselineRefused`, exit 8) before anything is copied. Its scope is compared with the run's
/// once the run's operators are chosen: the configuration's, or `--operators`', for `run`, and the plan's for a run of
/// a test plan, so it comes after `LoadConfiguration`, and after `LoadMuterTestPlan`. A run of one mutant (`--mutant`)
/// discovers with every operator and compares no survivors, so only its file is checked.
struct LoadBaselineFile: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(with state: AnyMutationTestState) async throws -> [MutationTestState.Change] {
        guard let path = state.runOptions.baseline else { return [] }
        let file = try BaselineFile.load(at: path, using: fileManager)
        if state.runOptions.mutant == nil {
            try BaselineRefused.check(Self.scope(of: state), against: file, subject: "this run")
        }
        return [.baselineFileLoaded(file)]
    }

    /// What a run with `state` records in a baseline file, and compares with one: its configuration after the flags
    /// that override it, its operators and whether it skips coverage, as its results header records them.
    static func scope(of state: AnyMutationTestState) -> BaselineScope {
        BaselineScope(
            configuration: state.muterConfiguration,
            operators: state.mutationOperatorList,
            skipCoverage: state.runOptions.skipCoverage
        )
    }
}
