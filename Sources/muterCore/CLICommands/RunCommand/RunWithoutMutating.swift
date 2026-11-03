import ArgumentParser
import Foundation

struct RunWithoutMutating: RunCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-without-mutating",
        abstract: "Performs mutation testing using the test plan."
    )

    @OptionGroup var options: RunArguments
    @OptionGroup var testing: TestingArguments
    @OptionGroup var reportOptions: ReportArguments
    // A run of a test plan resumes as `run` does. The plan's copy stands for the project: a resume compares its files.
    @OptionGroup var resuming: ResumeArguments

    // After the option groups, so it comes last in the help.
    @Option(
        name: .customLong("plan-ignoring"),
        help: ArgumentHelp(
            "Test the plan although files it mutates that match this glob changed since mutate-without-running made "
                + "it; * also matches /. Repeatable.",
            valueName: "glob"
        )
    )
    var planIgnoring: [String] = []

    @Argument(
        help: "The path for the test plan."
    )
    var testPlanURL: URL?

    init() {}

    /// The options the command line gives the run.
    var runOptions: Run.Options {
        Run.Options(
            reportFormat: reportOptions.reportFormat,
            reportURL: reportOptions.reportURL,
            skipCoverage: options.skipCoverage,
            skipUpdateCheck: options.skipUpdateCheck,
            verbose: options.verbose,
            configurationURL: options.configurationURL,
            testPlanURL: testPlanURL,
            workers: testing.workers,
            timeout: testing.timeout,
            resumeURL: resuming.resume,
            resumeIgnoring: resuming.resumeIgnoring,
            forceResume: resuming.forceResume,
            planIgnoring: planIgnoring
        )
    }

    func run() async throws {
        try await run(with: runOptions)
    }

    func validate() throws {
        if testPlanURL == nil {
            throw MuterError.literal(reason: "Please provide the path to the test plan json.")
        }
    }
}
