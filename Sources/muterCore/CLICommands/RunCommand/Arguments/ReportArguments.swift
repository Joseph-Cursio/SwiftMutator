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
            "Exit with status 2 when the headline mutation score, counting any mutant taken out of the build with "
                + "others as not killed, is below this percent, from 0 to 100, or every mutant was a build error, once "
                + "the report is written. For a run, in place of failUnder.",
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

    @Option(
        name: .customLong("property-tests"),
        help: ArgumentHelp(
            "Split the report's kills between example tests and the property tests this glob matches by name or by "
                + "the file their issue was recorded in; * matches any characters. Repeatable. In place of "
                + "propertyTests.",
            valueName: "glob"
        )
    )
    var propertyTests: [String] = []

    /// `--property-tests`' globs, or nil when none was given, which leaves the configuration's.
    var propertyTestGlobs: [String]? {
        propertyTests.isEmpty ? nil : propertyTests
    }

    func validate() throws {
        if let problem = PropertyTestPattern.problem(with: propertyTests) {
            throw ValidationError("--property-tests: \(problem).")
        }
    }
}
