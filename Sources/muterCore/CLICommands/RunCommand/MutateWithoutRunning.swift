import ArgumentParser

struct MutateWithoutRunning: RunCommand {
    static let configuration = CommandConfiguration(
        commandName: "mutate-without-running",
        abstract: "Mutates the source code and outputs the test plan as JSON."
    )

    // First, as in `run`'s help. The plan records what they chose, and a run that tests the plan records it too.
    @OptionGroup var selection: MutantSelectionArguments
    @OptionGroup var options: RunArguments
    @OptionGroup var copying: ProjectCopyArguments

    init() {
        // ArgumentParser sets the properties from the command line.
    }

    /// The options the command line gives the run.
    var runOptions: Run.Options {
        Run.Options(
            skipCoverage: options.skipCoverage,
            skipUpdateCheck: options.skipUpdateCheck,
            configurationURL: options.configurationURL,
            projectFolder: options.projectFolder,
            filesToMutate: selection.filesToMutate,
            exclude: selection.exclude,
            mutationOperatorsList: selection.mutationOperatorsList,
            operatorsAreNamed: selection.operatorsAreNamed,
            skipOperators: selection.skippedOperators,
            verbose: options.verbose,
            quiet: options.quiet,
            xcodebuild: options.xcodebuild,
            buildTimeout: options.buildTimeout,
            keyFlags: KeyFlags(from: [selection, options, copying]),
            createTestPlan: true
        )
    }

    func run() async throws {
        try await run(with: runOptions)
    }
}
