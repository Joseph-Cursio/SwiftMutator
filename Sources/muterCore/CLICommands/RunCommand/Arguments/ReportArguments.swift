import ArgumentParser
import Foundation

/// How a command reports, for `run`, `run-without-mutating` and `report`.
struct ReportArguments: ParsableArguments {
    @Option(
        name: [.customShort("f"), .customLong("format")],
        help: "The report format: \(ReportFormat.description)",
        transform: {
            guard let report = ReportFormat(rawValue: $0) else {
                throw MuterError.literal(reason: ReportFormat.description)
            }
            return report
        }
    )
    var reportFormat: ReportFormat = .plain

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Output file for the report to be saved."
    )
    var reportURL: URL?

    @Option(
        name: .customLong("fail-under"),
        help: ArgumentHelp(
            "Exit with status 2 when the headline mutation score is below this percent, from 0 to 100, "
                + "once the report is written. For a run, in place of failUnder.",
            valueName: "percent"
        ),
        transform: { text in
            guard let percent = ScoreGate.percent(text) else {
                throw ValidationError(
                    "give a percent from 0 to 100, with at most \(ScoreGate.maximumDecimals) decimals, such as 80 "
                        + "or 72.5."
                )
            }
            return percent
        }
    )
    var failUnder: Double?
}
