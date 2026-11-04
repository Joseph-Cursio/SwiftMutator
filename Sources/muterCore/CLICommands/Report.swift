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
            "A run's results file, or the log folder in <project>_muter_logs of any of the run's sessions. "
                + "Several, one for each shard of a run --shard split, are merged into one report.",
            valueName: "results"
        )
    )
    var results: [URL]

    @OptionGroup var reportOptions: ReportArguments

    @Flag(
        name: .customLong("force-merge"),
        help: ArgumentHelp(
            "Merge shards' results although their SwiftMutator build, toolchain or SDK differ. "
                + "With one file, it does nothing."
        )
    )
    var forceMerge = false

    @Option(
        name: .customLong("merge-ignoring"),
        help: ArgumentHelp(
            "Merge shards' results although project files matching this glob differ between them; * also matches /. "
                + "Repeatable. With one file, it does nothing.",
            valueName: "glob"
        )
    )
    var mergeIgnoring: [String] = []

    @Option(
        name: .customLong("summary"),
        help: ArgumentHelp(
            "Also save the run's summary.json, its score, counts and details for scripts, at this path.",
            valueName: "path"
        ),
        transform: { URL(fileURLWithPath: $0) }
    )
    var summary: URL?

    init() {}

    /// The status `report` exits with, once the report is made, for a run that stopped on an error: the one the run
    /// itself exited with (`RunCommand.run(with:)`), so a script that checks the report fails as one that checked the
    /// run would. A run that finished, was interrupted, or has no end line yet exits 0. Shards' files exit with it when
    /// the report is known to lack results (`MergedShards.lacksResults`).
    static let stoppedOnAnError = ExitCode.stoppedOnAnError

    func run() async throws {
        let report = ResultsReport(
            format: reportOptions.reportFormat,
            outputPath: reportOptions.reportURL?.path,
            summaryPath: summary?.path
        )
        let stopped = try report.make(from: results.map(\.path), forcing: forceMerge, ignoring: mergeIgnoring)
        if stopped {
            throw Self.stoppedOnAnError
        }
    }
}
