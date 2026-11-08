import ArgumentParser
import Foundation

struct RunWithoutMutating: RunCommand {
    static let configuration = CommandConfiguration(
        commandName: "run-without-mutating",
        abstract: "Performs mutation testing using the test plan."
    )

    // First, as in `run`'s help it comes before the other option groups.
    @OptionGroup var lone: MutantArguments
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
            reports: reportOptions.reportRequests,
            skipCoverage: options.skipCoverage,
            skipUpdateCheck: options.skipUpdateCheck,
            verbose: options.verbose,
            configurationURL: options.configurationURL,
            testPlanURL: testPlanURL,
            workers: testing.workers,
            timeout: testing.timeout,
            buildTimeout: options.buildTimeout,
            failUnder: reportOptions.failUnder,
            baseline: reportOptions.baseline,
            maxNewSurvivors: reportOptions.allowedNewSurvivors,
            writeBaseline: reportOptions.writeBaseline,
            propertyTests: reportOptions.propertyTestGlobs,
            resumeURL: resuming.resume,
            resumeIgnoring: resuming.resumeIgnoring,
            forceResume: resuming.forceResume,
            planIgnoring: planIgnoring,
            mutant: lone.mutant
        )
    }

    func run() async throws {
        try await run(with: runOptions)
    }

    /// `--mutant` tests one of the plan's mutants on its own, which no stopped run of the plan can continue, and whose
    /// survivors make no baseline file. A stopped run writes each report's partial report beside it, which no other
    /// report may take.
    func validate() throws {
        if testPlanURL == nil {
            throw MuterError.literal(reason: "Please provide the path to the test plan json.")
        }
        try reportOptions.validateForARun()
        if lone.mutant != nil, resuming.resume != nil {
            throw ValidationError("--mutant can't be given with --resume.")
        }
        if lone.mutant != nil, reportOptions.writeBaseline != nil {
            throw ValidationError(
                "--write-baseline can't be given with --mutant: a baseline file holds a whole run's survivors."
            )
        }
    }
}
