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
        name: .customLong("report"),
        help: ArgumentHelp(
            "Also save a report in another format, as format:path, such as \(ReportRequest.example). Repeatable. "
                + "For a run, in place of reports.",
            valueName: "format:path"
        ),
        transform: { text in
            switch ReportRequest.parse(text) {
            // Resolved now, as -o's path is.
            case let .success(request): return request.resolved
            case let .failure(problem): throw ValidationError("\(problem).")
            }
        }
    )
    var reports: [ReportRequest] = []

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
        name: .customLong("baseline"),
        help: ArgumentHelp(
            "Compare the survivors with those of this baseline file, which --write-baseline saved, and exit with "
                + "status 2 when more are new than --max-new-survivors allows, once the report is written. Only the "
                + "mutants tested are compared. Exit with status 8 if the file can't be read, or records another "
                + "scope: other operators, or another configuration.",
            valueName: "path"
        )
    )
    var baseline: String?

    @Option(
        name: .customLong("max-new-survivors"),
        help: ArgumentHelp(
            "With --baseline, how many new survivors pass: a whole number, 0 or more. 0 when not given.",
            valueName: "count"
        ),
        transform: { text in
            guard let count = NewSurvivorsCheck.allowed(text) else {
                throw ValidationError("give a whole number of survivors, 0 or more, such as 3.")
            }
            return count
        }
    )
    var maxNewSurvivors: Int?

    @Option(
        name: .customLong("write-baseline"),
        help: ArgumentHelp(
            "Save the survivors to a baseline file at this path, such as muter.baseline.yml, for --baseline to "
                + "compare later runs with. Only a whole run's results make one. It may be --baseline's own file, "
                + "which is read first.",
            valueName: "path"
        ),
        // Made absolute now, as `-o`'s path is: a run saves it once it has moved into the project's copy.
        transform: { URL(argument: $0)?.path ?? $0 }
    )
    var writeBaseline: String?

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

    /// `--report`'s requests, or nil when none was given, which leaves the configuration's `reports`.
    var reportRequests: [ReportRequest]? {
        reports.isEmpty ? nil : reports
    }

    /// `-o`'s report, `--report`'s and `--write-baseline`'s file, by how a refusal names each, for
    /// `ReportRequest.clash(among:ofARun:)`.
    var outputs: [ReportRequest.Output] {
        (reportURL.map { [("-o \($0.path)", $0.path)] } ?? []) + reports.map { ("--report \($0)", $0.path) }
            + (writeBaseline.map { [("--write-baseline \($0)", URL.expandingTilde($0))] } ?? [])
    }

    /// `--max-new-survivors`' count, 0 when `--baseline` is given without it; nil without `--baseline`.
    var allowedNewSurvivors: Int? {
        baseline == nil ? nil : maxNewSurvivors ?? 0
    }

    /// Refuses two reports at one path, for every command: a run's at another's partial report too is refused by
    /// `validateForARun()`, as `report` writes none. `--max-new-survivors` says only what `--baseline` allows.
    func validate() throws {
        if let problem = PropertyTestPattern.problem(with: propertyTests) {
            throw ValidationError("--property-tests: \(problem).")
        }
        if maxNewSurvivors != nil, baseline == nil {
            throw ValidationError("--max-new-survivors only applies with --baseline.")
        }
        try refuseAClash(ofARun: false)
    }

    /// Refuses a report at the path another's partial report takes when a run stops, for `run` and
    /// `run-without-mutating`, which `validate()` leaves to them.
    func validateForARun() throws {
        try refuseAClash(ofARun: true)
    }

    private func refuseAClash(ofARun isARun: Bool) throws {
        if let clash = ReportRequest.clash(among: outputs, ofARun: isARun) {
            throw ValidationError("\(clash): give each report a path of its own.")
        }
    }
}
