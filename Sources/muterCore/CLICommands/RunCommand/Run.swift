import ArgumentParser
import Foundation

struct Run: RunCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Performs mutation testing for the Swift project contained within the current directory."
    )

    @Option(help: "Only mutate a given list of source code files.")
    var filesToMutate: [String] = []

    @Option(
        parsing: .upToNextOption,
        help: "The list of mutant operators to be used: \(MutationOperator.Id.description)",
        transform: {
            guard let `operator` = MutationOperator.Id(rawValue: $0) else {
                throw MuterError.literal(reason: MutationOperator.Id.description)
            }

            return `operator`
        }
    )
    var operators: [MutationOperator.Id] = MutationOperator.Id.allCases

    @OptionGroup var options: RunArguments
    @OptionGroup var reportOptions: ReportArguments

    // After the option groups, so they come last in the help. Not in `RunArguments`, which other commands share.
    @Option(
        name: .customLong("resume"),
        help: ArgumentHelp(
            "Continue a stopped run from its results file, or the log folder that holds it. "
                + "Only mutants without a result that still holds are tested.",
            valueName: "results"
        )
    )
    var resume: URL?

    @Option(
        name: .customLong("resume-ignoring"),
        help: ArgumentHelp(
            "With --resume, reuse results although project files matching this glob changed; * also matches /. "
                + "Repeatable.",
            valueName: "glob"
        )
    )
    var resumeIgnoring: [String] = []

    @Flag(
        name: .customLong("force-resume"),
        help: "With --resume, reuse results although SwiftMutator, the toolchain or the SDK changed."
    )
    var forceResume = false

    @Option(
        name: .customLong("reuse"),
        help: ArgumentHelp(
            "Start a new run from an earlier run's results file, or the log folder that holds it, finished or not. "
                + "Only mutants without a result that still holds are tested, and the new run writes a results file "
                + "of its own.",
            valueName: "results"
        )
    )
    var reuse: URL?

    @Option(
        name: .customLong("reuse-ignoring"),
        help: ArgumentHelp(
            "With --reuse, reuse results although project files matching this glob changed; * also matches /. "
                + "Test files are never waived. Repeatable.",
            valueName: "glob"
        )
    )
    var reuseIgnoring: [String] = []

    @Flag(
        name: .customLong("force-reuse"),
        help: "With --reuse, reuse results although SwiftMutator, the toolchain or the SDK changed."
    )
    var forceReuse = false

    init() {}

    /// The options the command line gives the run.
    var runOptions: Run.Options {
        Run.Options(
            filesToMutate: filesToMutate,
            reportFormat: reportOptions.reportFormat,
            reportURL: reportOptions.reportURL,
            mutationOperatorsList: !operators.isEmpty ? operators : .allOperators,
            skipCoverage: options.skipCoverage,
            skipUpdateCheck: options.skipUpdateCheck,
            verbose: options.verbose,
            configurationURL: options.configurationURL,
            resumeURL: resume,
            reuseURL: reuse,
            // Only one of each pair can be given: `validate()` ties each to its own option.
            resumeIgnoring: resume == nil ? reuseIgnoring : resumeIgnoring,
            forceResume: resume == nil ? forceReuse : forceResume
        )
    }

    func run() async throws {
        try await run(with: runOptions)
    }

    /// `--resume` continues a run's own results file and `--reuse` starts a new one, so only one can be given.
    /// `--resume-ignoring` and `--force-resume` only say what a resume may reuse, and `--reuse-ignoring` and
    /// `--force-reuse` what a reuse may.
    func validate() throws {
        if resume != nil, reuse != nil {
            throw ValidationError("--resume and --reuse can't be given together.")
        }
        if resume == nil {
            if !resumeIgnoring.isEmpty {
                throw ValidationError("--resume-ignoring only applies with --resume.")
            }
            if forceResume {
                throw ValidationError("--force-resume only applies with --resume.")
            }
        }
        if reuse == nil {
            if !reuseIgnoring.isEmpty {
                throw ValidationError("--reuse-ignoring only applies with --reuse.")
            }
            if forceReuse {
                throw ValidationError("--force-reuse only applies with --reuse.")
            }
        }
    }
}
