import Foundation
import Plot

/// The HTML report's tables of mutants: each file's score, every mutant applied, the survivors and those not
/// covered, with what each changes and what killed it.
extension Node where Context: HTML.BodyContext {
    static func mutationOperatorsPerFile(from testReport: MuterTestReport) -> Self {
        .div(
            .class("mutation-operators-per-file"),
            .div(
                .class("toggle"),
                .input(
                    .id("show-more-mutation-operators-per-file"),
                    .type(.checkbox),
                    .attribute(named: "onclick", value: "showHide(this.checked, 'mutation-operators-per-file');")
                ),
                .label(.for("show-more-mutation-operators-per-file"), "Show all")
            ),
            .mutationScoreTable(from: testReport.fileReports)
        )
    }

    static func mutationScoreTable(from fileReports: [FileReport]) -> Self {
        .table(
            .id("mutation-operators-per-file"),
            .thead(
                .tr(
                    .th("File"),
                    .th("# of Introduced Mutants"),
                    .th("Mutation Score")
                )
            ),
            .tbody(
                .forEach(fileReports.sorted()) { report in
                    .tr(
                        .td(.class("left-aligned"), .text(report.relativePath)),
                        .td(.class("right-aligned"), "\(report.appliedOperators.count)"),
                        .td(.class("right-aligned"), .style("color: \(report.scoreColor)"), "\(report.mutationScore)")
                    )
                }
            )
        )
    }

    static func appliedOperators(from testReport: MuterTestReport) -> Self {
        .div(
            .class("applied-operators"),
            .div(
                .class("toggle"),
                .input(
                    .id("show-more-applied-operators"),
                    .type(.checkbox),
                    .attribute(named: "onclick", value: "showHide(this.checked, 'applied-operators');")
                ),
                .label(.for("show-more-applied-operators"), "Show all")
            ),
            .appliedOperatorsTable(from: testReport.fileReports)
        )
    }

    static func appliedOperatorsTable(from fileReports: [FileReport]) -> Self {
        let reports = fileReports.sorted().flatMap { report in
            report.appliedOperators.map { appliedOperator in
                (relativePath: report.relativePath, appliedOperator: appliedOperator)
            }
        }
        let showsKillingTests = fileReports.showsKillingTests
        let showsReuse = fileReports.showsReuse
        let showsDurations = fileReports.showsDurations

        return .table(
            .id("applied-operators"),
            .thead(
                .tr(
                    .th("File"),
                    .th("Applied Mutation Operator"),
                    .th("Changes"),
                    .th("Mutation Test Result"),
                    .if(showsKillingTests, .th("Killed By")),
                    .if(showsReuse, .th("Reused")),
                    .if(showsDurations, .th("Duration"))
                )
            ),
            .tbody(
                .forEach(reports) { report -> Node<HTML.TableContext> in
                    .tr(
                        .td(
                            .class("left-aligned"),
                            .text(MuterTestReport.place(report.appliedOperator, in: report.relativePath))
                        ),
                        .td(
                            .class("left-aligned"),
                            .attribute(
                                named: "title",
                                value: report.appliedOperator.mutationPoint.mutationOperatorId.explanation
                            ),
                            .raw("<wbr>\(report.appliedOperator.mutationPoint.mutationOperatorId.friendlyName)<wbr>")
                        ),
                        .td(.class("mutation-snapshot"), .diff(of: report.appliedOperator)),
                        .td(
                            .raw(report.appliedOperator.outcomeIcon)
                        ),
                        .if(showsKillingTests, .td(.class("left-aligned"), .killedBy(report.appliedOperator))),
                        .if(showsReuse, .td(.text(report.appliedOperator.reusedCell))),
                        .if(showsDurations, .td(.class("right-aligned"), .text(report.appliedOperator.durationCell)))
                    )
                }
            )
        )
    }

    /// The survivors, which are the mutants to act on, by path, line and column: each one's place, operator, verdict
    /// and change. Not collapsible, so no script.
    static func survivors(from testReport: MuterTestReport) -> Self {
        let survivors = testReport.survivors
        guard !survivors.isEmpty else {
            return .div(.class("survivors"), .p("No mutant survived or timed out."))
        }
        return .div(
            .class("survivors"),
            .p(.text(PlainTextReporter.survivorsIntroduction(survivors.count))),
            .table(
                .id("survivors"),
                .thead(
                    .tr(
                        .th("Place"),
                        .th("Applied Mutation Operator"),
                        .th("Changes"),
                        .th("Mutation Test Result"),
                        .if(testReport.triageSummary != nil, .th("Triage"))
                    )
                ),
                .tbody(
                    .forEach(survivors) { survivor -> Node<HTML.TableContext> in
                        .tr(
                            .td(
                                .class("left-aligned"),
                                .text(MuterTestReport.place(survivor.appliedOperator, in: survivor.relativePath))
                            ),
                            .td(
                                .class("left-aligned"),
                                .attribute(
                                    named: "title",
                                    value: survivor.appliedOperator.mutationPoint.mutationOperatorId.explanation
                                ),
                                .raw("<wbr>\(survivor.appliedOperator.mutationPoint.mutationOperatorId.friendlyName)"
                                    + "<wbr>")
                            ),
                            .td(.class("mutation-snapshot"), .diff(of: survivor.appliedOperator)),
                            .td(.raw("\(survivor.appliedOperator.testSuiteOutcome.asIcon)")),
                            // Text only: a note can hold anything.
                            .if(
                                testReport.triageSummary != nil,
                                .td(.class("left-aligned"), .text(survivor.appliedOperator.triage?.text ?? "-"))
                            )
                        )
                    }
                )
            )
        )
    }

    /// The mutants not covered, by path, line and column, as the survivors are shown; nothing when there are none.
    static func notCovered(from testReport: MuterTestReport) -> Self {
        let mutants = testReport.notCovered
        guard !mutants.isEmpty else { return .empty }
        return .div(
            .class("survivors"),
            .p(.text(PlainTextReporter.notCoveredIntroduction(mutants.count))),
            .table(
                .id("not-covered"),
                .thead(
                    .tr(
                        .th("Place"),
                        .th("Applied Mutation Operator"),
                        .th("Changes"),
                        .if(testReport.triageSummary != nil, .th("Triage"))
                    )
                ),
                .tbody(
                    .forEach(mutants) { item -> Node<HTML.TableContext> in
                        .tr(
                            .td(
                                .class("left-aligned"),
                                .text(MuterTestReport.place(item.appliedOperator, in: item.relativePath))
                            ),
                            .td(
                                .class("left-aligned"),
                                .attribute(
                                    named: "title",
                                    value: item.appliedOperator.mutationPoint.mutationOperatorId.explanation
                                ),
                                .raw("<wbr>\(item.appliedOperator.mutationPoint.mutationOperatorId.friendlyName)"
                                    + "<wbr>")
                            ),
                            .td(.class("mutation-snapshot"), .diff(of: item.appliedOperator)),
                            .if(
                                testReport.triageSummary != nil,
                                .td(.class("left-aligned"), .text(item.appliedOperator.triage?.text ?? "-"))
                            )
                        )
                    }
                )
            )
        )
    }

    /// The Killed By cell, with more than one test recorded opening to every one. Text nodes only: Plot escapes text,
    /// but not attribute values, and Swift Testing's names can hold `"`.
    static func killedBy(_ appliedOperator: AppliedMutationOperator) -> Self {
        guard let tests = appliedOperator.killedByTests?.tests, tests.count > 1 else {
            return .text(appliedOperator.killedByCell)
        }
        return .details(
            .summary(.text(appliedOperator.killedByCell)),
            .ul(
                .forEach(tests) { test in
                    .li(.text(test.location.map { "\(test.name) — \($0)" } ?? test.name))
                }
            )
        )
    }

    /// The line the mutant changes, before and after, when its original file gives it; else its snapshot's change.
    /// Text nodes only: a line of code can hold anything.
    static func diff(of appliedOperator: AppliedMutationOperator) -> Self {
        guard let change = appliedOperator.sourceChange else { return snapshotDiff(of: appliedOperator) }
        return .div(
            .class("source-change"),
            .forEach(change.lines) { line in
                .div(
                    .class(line.hasPrefix("-") ? "source-line snapshot-before" : "source-line snapshot-after"),
                    .text(line)
                )
            }
        )
    }

    static func snapshotDiff(of appliedOperator: AppliedMutationOperator) -> Self {
        .div(
            .class("snapshot-changes"),
            .if(
                appliedOperator.testSuiteOutcome == .noCoverage && !appliedOperator.isANotCoveredMutant,
                .span(
                    .class("snapshot-no-coverage"),
                    ""
                ),
                else:
                .if(
                    appliedOperator.mutationPoint.mutationOperatorId == .removeSideEffects,
                    .span(
                        .class("snapshot-before"),
                        "\(appliedOperator.mutationSnapshot.before)"
                    ),
                    else:
                    .group(
                        .span(.class("snapshot-before"), "\(appliedOperator.mutationSnapshot.before)"),
                        .span(.class("snapshot-arrow"), "\u{2192}"), // →
                        .span(.class("snapshot-after"), "\(appliedOperator.mutationSnapshot.after)")
                    )
                )
            )
        )
    }
}
