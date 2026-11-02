import ArgumentParser
import Foundation

/// `swift-mutator report`: a run's report in any format, made from its results file, or from its shards' results files
/// merged. A plain command, not a `RunCommand`: it mutates nothing, so it prints no banner, makes no log folder, and
/// handles no signals.
struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Builds a report from a run's results file, or from its shards' results files merged."
    )

    @Argument(
        help: ArgumentHelp(
            "A run's results file, or the run's log folder in <project>_muter_logs that holds it. "
                + "Several, one for each shard of a run --shard split, are merged into one report.",
            valueName: "results"
        )
    )
    var results: [URL]

    @OptionGroup var reportOptions: ReportArguments

    @Flag(
        name: .customLong("force-merge"),
        help: "Merge shards' results although their SwiftMutator build, toolchain or SDK differ."
    )
    var forceMerge = false

    @Option(
        name: .customLong("merge-ignoring"),
        help: ArgumentHelp(
            "Merge shards' results although project files matching this glob differ between them; * also matches /. "
                + "Repeatable.",
            valueName: "glob"
        )
    )
    var mergeIgnoring: [String] = []

    init() {}

    /// The status `report` exits with, once the report is made, for a run that stopped on an error: the one the run
    /// itself exited with (`RunCommand.run(with:)`), so a script that checks the report fails as one that checked the
    /// run would. A run that finished, was interrupted, or has no end line yet exits 0. Merged shards exit with it too
    /// when a shard that holds mutants has no results file among them.
    static let stoppedOnAnError = ExitCode(-1)

    /// `--force-merge` and `--merge-ignoring` only say what a merge may let through.
    func validate() throws {
        if results.count == 1 {
            if forceMerge {
                throw ValidationError("--force-merge only applies when several shards' results files are given.")
            }
            if !mergeIgnoring.isEmpty {
                throw ValidationError("--merge-ignoring only applies when several shards' results files are given.")
            }
        }
    }

    func run() async throws {
        let stopped = try ResultsReport(format: reportOptions.reportFormat, outputPath: reportOptions.reportURL?.path)
            .make(from: results.map(\.path), forcing: forceMerge, ignoring: mergeIgnoring)
        if stopped {
            throw Self.stoppedOnAnError
        }
    }
}
