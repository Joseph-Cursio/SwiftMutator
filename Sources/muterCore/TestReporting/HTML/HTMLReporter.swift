import Foundation
import Plot

struct HTMLReporter: Reporter {
    @Dependency(\.now)
    private var now: Now

    func report(from outcome: MutationTestOutcome) -> String {
        htmlReport(
            outcome,
            now
        )
    }
}

private func htmlReport(
    _ outcome: MutationTestOutcome,
    _ now: Now
) -> String {
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
                    .unwrap(testReport.killingTestSummary) { summary in
                        .group(
                            .divider("Killing Tests"),
                            .killingTestsTable(summary, mutationScore: testReport.globalMutationScore)
                        )
                    },
                    .unwrap(testReport.propertyKillSummary) { summary in
                        .group(
                            .divider("Examples and Properties"),
                            .propertyKillsTable(summary)
                        )
                    },
                    .unwrap(testReport.triageSummary) { summary in
                        .group(
                            .divider("Triage"),
                            .triageSection(summary)
                        )
                    },
                    .unwrap(testReport.run) { run in
                        .group(
                            .divider("Run"),
                            // Text only: paths and versions can hold anything.
                            .div(.class("run"), .forEach(run.lines) { .p(.text($0)) })
                        )
                    }
                ),
                .muterFooter(now: now)
            )
        )
    ).render()
}

private extension Date {
    var string: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d yyyy HH:mm:ss"

        return formatter.string(from: self)
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

extension Node where Context: HTML.BodyContext {
    static func muterHeader(from testReport: MuterTestReport) -> Self {
        .header(
            .div(.class("logo"), .raw(muterLogo)),
            .div(
                .class("header-item"),
                .div(
                    .class("box"),
                    .style("background-color: \(testReport.scoreColor)"),
                    .p(.class("small"), "Mutation Score"),
                    .h1("\(testReport.globalMutationScore)%")
                )
            ),
            .unwrap(testReport.suspectSummary) { summary in
                .div(
                    .class("header-item"),
                    .div(
                        .class("box"),
                        .style("background-color: #f39c12"),
                        .p(
                            .class("small"),
                            .text(summary.scoreWithoutSuspectsIsALowerBound
                                ? "Without Suspect Tests, at least" : "Without Suspect Tests")
                        ),
                        .h1(.text("\(summary.scoreWithoutSuspects(mutationScore: testReport.globalMutationScore))%"))
                    )
                )
            },
            .unwrap(testReport.projectCodeCoverage) { coverage in
                .div(
                    .class("header-item"),
                    .div(
                        .class("box"),
                        .style("background-color: \(coloredMutationScore(for: coverage))"),
                        .p(.class("small"), "Code Coverage"),
                        .h1("\(coverage)%")
                    )
                )
            },
            .unwrap(testReport.since) { since in
                .div(
                    .class("header-item"),
                    .div(
                        .class("box"),
                        .style("background-color: #8e44ad"),
                        .p(.class("small"), .text((since.changedLines ? "Lines" : "Files") + " changed since")),
                        .h1(.text(since.ref))
                    )
                )
            },
            .unwrap(testReport.shards) { shards in
                .div(
                    .class("header-item"),
                    .div(
                        .class("box"),
                        .style("background-color: #8e44ad"),
                        .p(
                            .class("small"),
                            .text(
                                (shards.indices.count == 1 ? "Shard" : "Shards")
                                    + " tested, of \(shards.mutantsInAllShards) mutants"
                                    + (testReport.sample == nil ? "" : " in the sample")
                            )
                        ),
                        .h1(.text(shards.indices.map(String.init).joined(separator: ", ") + " of \(shards.count)"))
                    )
                )
            },
            .unwrap(testReport.sample) { sample in
                .div(
                    .class("header-item"),
                    .div(
                        .class("box"),
                        .style("background-color: #8e44ad"),
                        .p(
                            .class("small"),
                            .text("Sample tested, of \(sample.mutantsSampledFrom) mutants (seed \(sample.seed))")
                        ),
                        .h1(.text(
                            (sample.margin != nil && sample.mutantsTested < sample.mutantsSampled
                                ? "\(sample.mutantsTested) of \(sample.mutantsSampled), "
                                : "\(sample.mutantsSampled), ")
                                + (sample.margin.map { "score ± \($0)" } ?? "\(sample.mutantsTested) with a result")
                        ))
                    )
                )
            },
            .unwrap(testReport.mutant) { mutant in
                .div(
                    .class("header-item"),
                    .div(
                        .class("box"),
                        .style("background-color: #8e44ad"),
                        .p(.class("small"), .text(MuterTestReport.oneMutantSentence(mutant))),
                        .h1("One mutant")
                    )
                )
            },
            .div(
                .class("header-item"),
                .div(
                    .class("box"),
                    .style("background-color: #3498db"),
                    .p(.class("small"), "Operators Applied"),
                    .h1("\(testReport.totalAppliedMutationOperators)")
                )
            )
        )
    }

    static func themeToggle() -> Self {
        .div(
            .button(.id("theme-toggle"), .class("theme-toggle"))
        )
    }

    static func summary(
        from testReport: MuterTestReport,
        newVersion: String
    ) -> Self {
        .div(
            .p(
                "📝 In total, SwiftMutator introduced ",
                .span(.class("strong"), "\(testReport.totalAppliedMutationOperators)"),
                " mutants in ",
                .span(.class("strong"), "\(testReport.fileReports.count)"),
                " files."
            ),
            .p("⏰ SwiftMutator took \(testReport.timeElapsed) to run."),
            .unwrap(testReport.mutantsByOutcome) { .p(.text("📊 By outcome: \($0.tally).")) },
            // Text only: the warning names tests, whose names can hold anything.
            .unwrap(testReport.suspectWarning) { .p(.text("⚠️ \($0)")) },
            .if(
                !newVersion.isEmpty,
                .p("🆕 The version \(newVersion) of SwiftMutator is available")
            )
        )
    }

    static func divider(_ title: String) -> Self {
        .div(
            .class("divider"),
            .span(.class("divider-content"), "\(title)")
        )
    }

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

    static func mutationScoreTable(from fileReports: [MuterTestReport.FileReport]) -> Self {
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

    static func appliedOperatorsTable(from fileReports: [MuterTestReport.FileReport]) -> Self {
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
    static func killedBy(_ appliedOperator: MuterTestReport.AppliedMutationOperator) -> Self {
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

    /// The Killing Tests section: what it counts, then the tests, with every name whole, then what it says of suspect
    /// tests against the headline `mutationScore`. Text nodes only, as in the Killed By column; not collapsible, so
    /// no script.
    static func killingTestsTable(_ summary: KillingTestSummary, mutationScore: Int) -> Self {
        .div(
            .class("killing-tests"),
            .p(.text(KillingTestSummary.introduction)),
            .forEach(summary.countSentences) { .p(.text($0)) },
            .if(
                !summary.tests.isEmpty,
                .table(
                    .thead(
                        .tr(
                            .th("Test"),
                            .th("File"),
                            .th("Mutants"),
                            .th("Files"),
                            .th("Only Recorded Failure Of"),
                            .th("Suspect")
                        )
                    ),
                    .tbody(
                        .forEach(summary.tests) { test -> Node<HTML.TableContext> in
                            .tr(
                                .td(.class("left-aligned"), .text(test.name)),
                                .td(.class("left-aligned"), .text(test.file ?? "-")),
                                .td(.class("right-aligned"), .text("\(test.mutants)")),
                                .td(.class("right-aligned"), .text("\(test.files)")),
                                .td(.class("right-aligned"), .text("\(test.onlyRecordedFailureOf)")),
                                .td(.text(test.suspectCell))
                            )
                        }
                    )
                )
            ),
            .unwrap(summary.shownTestsSentence) { .p(.text($0)) },
            .unwrap(summary.noVerdictSentence) { .p(.text($0)) },
            .forEach(summary.controlRunSentences) { .p(.text($0)) },
            .forEach(summary.testedAloneSentences) { .p(.text($0)) },
            .forEach(summary.suspectSentences(mutationScore: mutationScore)) { .p(.text($0)) }
        )
    }

    /// The Examples and Properties section: how the kills split between the kinds of test, then the property tests,
    /// with every name whole. Text nodes only, as in the Killing Tests section.
    static func propertyKillsTable(_ summary: PropertyKillSummary) -> Self {
        .div(
            .class("killing-tests"),
            .p(.text(PropertyKillSummary.introduction + " " + summary.globSentence)),
            .forEach(summary.splitSentences) { .p(.text($0)) },
            .if(
                !summary.properties.isEmpty,
                .table(
                    .thead(.tr(.th("Property"), .th("File"), .th("Mutants"), .th("Only Recorded Killer Of"))),
                    .tbody(
                        .forEach(summary.properties) { property -> Node<HTML.TableContext> in
                            .tr(
                                .td(.class("left-aligned"), .text(property.name)),
                                .td(.class("left-aligned"), .text(property.file ?? "-")),
                                .td(.class("right-aligned"), .text("\(property.mutants)")),
                                .td(.class("right-aligned"), .text("\(property.onlyRecordedKillerOf)"))
                            )
                        }
                    )
                )
            ),
            .unwrap(summary.shownPropertiesSentence) { .p(.text($0)) }
        )
    }

    /// The Triage section: how far the survivors have been triaged, then the labels that need attention. Text nodes
    /// only: keys and paths can hold anything.
    static func triageSection(_ summary: TriageSummary) -> Self {
        .div(
            .class("killing-tests"),
            .p(.text(TriageSummary.introduction)),
            .p(.text(summary.countSentence)),
            .unwrap(summary.labelSentence) { .p(.text($0)) },
            .forEach(summary.attentionParagraphs) { paragraph in
                .group(
                    .p(.text(paragraph.first ?? "")),
                    .ul(.forEach(paragraph.dropFirst()) { .li(.text($0.trimmingCharacters(in: .whitespaces))) })
                )
            }
        )
    }

    /// The line the mutant changes, before and after, when its original file gives it; else its snapshot's change.
    /// Text nodes only: a line of code can hold anything.
    static func diff(of appliedOperator: MuterTestReport.AppliedMutationOperator) -> Self {
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

    static func snapshotDiff(of appliedOperator: MuterTestReport.AppliedMutationOperator) -> Self {
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

    static func muterFooter(now: () -> Date) -> Self {
        .footer(
            .class("footer"),
            "\(now().string)"
        )
    }
}

private extension MuterTestReport.AppliedMutationOperator {
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

private extension TestSuiteOutcome {
    // icons are from the collection: https://www.svgrepo.com/collection/openmoji-vectors/
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

private extension MuterTestReport.FileReport {
    var scoreColor: String { coloredMutationScore(for: mutationScore) }
}

private extension MuterTestReport {
    var scoreColor: String { coloredMutationScore(for: globalMutationScore) }
}

private func coloredMutationScore(for score: Int) -> String {
    switch score {
    case 0 ... 25: "#f70000"
    case 26 ... 50: "#ce9400"
    case 51 ... 75: "#92b300"
    default: "#51a100"
    }
}
