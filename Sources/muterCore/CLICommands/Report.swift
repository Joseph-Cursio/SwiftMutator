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
        // A leading `~` is the home folder, as for `-o`.
        transform: { URL(fileURLWithPath: URL.expandingTilde($0)) }
    )
    var summary: URL?

    @Option(
        name: .customLong("triage"),
        help: ArgumentHelp(
            "Show the labels in this triage file, if not muter.triage.yml in the run's project, or in the current "
                + "folder.",
            valueName: "path"
        )
    )
    var triage: String?

    init() {
        // ArgumentParser sets the properties from the command line.
    }

    /// Makes the report, then exits with the status `ResultsReport.make` gives once it is made: for a run that
    /// stopped on an error, the one the run itself exited with (`RunCommand.run(with:)`), 4 or 255, so a script that
    /// checks the report fails as one that checked the run would; for shards whose merged report is known to lack
    /// results (`MergedShards.lacksResults`), the status of the first shard that stopped on an error, 4 or 255, and
    /// otherwise 4 (`MergedShards.exitStatus`); else 2 for a score below `--fail-under`, every mutant a build error, a
    /// run that didn't finish with no results, more new survivors against `--baseline`'s file than
    /// `--max-new-survivors` allows, a score more than `--max-score-drop` points below the file's, or more doubtful
    /// kills than `--max-doubtful-kills` allows; and 8 for a baseline file it refuses (`BaselineRefused`), said as it
    /// is, before any report. A run that finished, was interrupted, or has no end line yet otherwise exits 0.
    func run() async throws {
        let report = ResultsReport(
            format: reportOptions.reportFormat,
            outputPath: reportOptions.reportURL?.path,
            // Only `--report`'s: the header's `reports:` would replace the run's own files.
            reports: reportOptions.reports,
            summaryPath: summary?.path,
            failUnder: reportOptions.failUnder,
            propertyTests: reportOptions.propertyTestGlobs,
            triagePath: triage,
            baselinePath: reportOptions.baseline,
            maxNewSurvivors: reportOptions.allowedNewSurvivors ?? 0,
            maxScoreDrop: reportOptions.maxScoreDrop,
            maxDoubtfulKills: reportOptions.maxDoubtfulKills,
            writeBaselinePath: reportOptions.writeBaseline
        )
        do {
            if let status = try report.make(from: results.map(\.path), forcing: forceMerge, ignoring: mergeIgnoring) {
                throw status
            }
        } catch let refused as BaselineRefused {
            dependency(\.errorPrinter)("\(refused)")
            throw ExitCode.baselineRefused
        }
    }
}
