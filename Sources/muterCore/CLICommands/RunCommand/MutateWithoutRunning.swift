import ArgumentParser
import Foundation

struct MutateWithoutRunning: RunCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mutate-without-running",
        abstract: "Mutates the source code and outputs the test plan as JSON."
    )

    // First, as in `run`'s help. The plan records what they chose, and a run that tests the plan records it too.
    @OptionGroup var selection: MutantSelectionArguments
    @OptionGroup var options: RunArguments

    init() {}

    /// The options the command line gives the run.
    var runOptions: Run.Options {
        Run.Options(
            filesToMutate: selection.filesToMutate,
            mutationOperatorsList: selection.mutationOperatorsList,
            skipCoverage: options.skipCoverage,
            skipUpdateCheck: options.skipUpdateCheck,
            verbose: options.verbose,
            configurationURL: options.configurationURL,
            createTestPlan: true
        )
    }

    func run() async throws {
        try await run(with: runOptions)
    }
}
