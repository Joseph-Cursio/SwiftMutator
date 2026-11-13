import Foundation
import Plot

struct HTMLReporter: Reporter {
    @Dependency(\.now)
    private var now: Now

    func report(from outcome: MutationTestOutcome) -> String {
        Self.page(of: outcome, now: now)
    }

    /// The report of `outcome`, dated `now`.
    private static func page(of outcome: MutationTestOutcome, now: Now) -> String {
        let testReport = MuterTestReport(from: outcome)

        return HTML(
            .lang(.english),
            .muterHeader(),
            .body(
                .div(
                    .themeToggle(),
                    .class("report"),
                    .muterHeader(from: testReport),
                    .main(
                        .class("summary"),
                        .summary(
                            from: testReport,
                            newVersion: outcome.newVersion
                        ),
                        .divider("Surviving Mutants"),
                        .survivors(from: testReport),
                        .notCovered(from: testReport),
                        .divider("Mutation Operators per File"),
                        .mutationOperatorsPerFile(from: testReport),
                        .divider("Applied Mutation Operators"),
                        .appliedOperators(from: testReport),
                        .summarySections(
                            from: testReport,
                            survivorsToldApart: PropertySurvivorRerunSummary.toldApart(in: outcome)
                        )
                    ),
                    .muterFooter(now: now)
                )
            )
        ).render()
    }

    /// A mutation score's color in the report: red up to 25, amber up to 50, light green up to 75, then green.
    static func scoreColor(for score: Int) -> String {
        switch score {
        case 0 ... 25: "#f70000"
        case 26 ... 50: "#ce9400"
        case 51 ... 75: "#92b300"
        default: "#51a100"
        }
    }
}

extension Node where Context == HTML.DocumentContext {
    static func muterHeader() -> Self {
        let normalizeCSS = normalize
        let reportCSS = css
        let css = normalizeCSS + reportCSS

        return .head(
            .title("SwiftMutator Report"),
            .meta(.charset(.utf8)),
            .style(css),
            .raw("<script>\(javascript)</script>")
        )
    }
}

extension AppliedMutationOperator {
    /// Its outcome's icon, titled as the tables say it. A mutant not covered has a survivor's icon, as its tests ran
    /// and passed, and the score counts it as one, where a file's row has the icon of one that was skipped.
    var outcomeIcon: String {
        guard isANotCoveredMutant else { return testSuiteOutcome.asIcon }
        return TestSuiteOutcome.passed.asIcon.replacingOccurrences(
            of: TestSuiteOutcome.passed.asMutationTestOutcome,
            with: outcomeWords
        )
    }
}

extension TestSuiteOutcome {
    /// Its icon in the HTML report, titled as the tables say it. The icons are from the collection:
    /// https://www.svgrepo.com/collection/openmoji-vectors/
    var asIcon: String {
        let icon: String
        switch self {
        case .passed:
            icon = testPassed

        case .failed,
             .runtimeError:
            icon = testFailed

        case .buildError:
            icon = testBuildError

        case .noCoverage:
            icon = skipped

        case .timeout:
            icon = testTimeout
        }

        return icon.replacingOccurrences(of: "$title$", with: asMutationTestOutcome)
    }
}

extension FileReport {
    /// Its score's color in the HTML report.
    var scoreColor: String { HTMLReporter.scoreColor(for: mutationScore) }
}

extension MuterTestReport {
    /// Its score's color in the HTML report.
    var scoreColor: String { HTMLReporter.scoreColor(for: globalMutationScore) }
}
