/// Loads the run's baseline file, `--baseline`'s or else `baseline:`'s, as the run starts, so a typo, a missing file or
/// one of another scope doesn't wait for a long run to end: refused (`BaselineRefused`, exit 8) before anything is
/// copied. Its scope is compared with the run's once the run's operators are chosen: the configuration's, or
/// `--operators`', for `run`, and the plan's for a run of a test plan, so it comes after `LoadConfiguration`, and after
/// `LoadMuterTestPlan`. A run of one mutant (`--mutant`) discovers with every operator and compares no survivors, so
/// only its file is checked. The command line can't tell whether the configuration gives a file, so the step is in
/// every list that tests, and does nothing without one. A refusal of the key's file says the key named it.
struct LoadBaselineFile: MutationStep {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    func run(with state: AnyMutationTestState) throws -> [MutationTestState.Change] {
        guard let path = state.muterConfiguration.gates.baseline else { return [] }
        do {
            let file = try BaselineFile.load(at: path, using: fileManager)
            if state.runOptions.mutant == nil {
                try BaselineRefused.check(Self.scope(of: state), against: file, subject: "this run")
            }
            return [.baselineFileLoaded(file)]
        } catch let refused as BaselineRefused where state.runOptions.baseline == nil {
            throw refused.namedByTheKey()
        }
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
