import ArgumentParser
import Foundation

struct RunWithoutMutating: RunCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-without-mutating",
        abstract: "Performs mutation testing using the test plan."
    )

    @OptionGroup var options: RunArguments
    @OptionGroup var reportOptions: ReportArguments

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
            testPlanURL: testPlanURL
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
