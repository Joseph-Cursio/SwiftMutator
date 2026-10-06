import ArgumentParser
import Foundation

/// `swift-mutator report`: a run's report in any format, made from its results file. A plain command, not a
/// `RunCommand`: it mutates nothing, so it prints no banner, makes no log folder, and handles no signals.
struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Builds a report from a run's results file."
    )

    @Argument(help: "A run's results file, or the run's log folder in <project>_muter_logs that holds it.")
    var results: URL

    @OptionGroup var reportOptions: ReportArguments

    init() {}

    func run() async throws {
        try ResultsReport(format: reportOptions.reportFormat, outputPath: reportOptions.reportURL?.path)
            .make(from: results.path)
    }
}
