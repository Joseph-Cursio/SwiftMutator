import Foundation
import Plot

/// The HTML report's optional sections: the killing tests, the examples and properties, the triage and the run.
extension Node where Context: HTML.BodyContext {
    /// The report's optional sections, each after its divider: the killing tests, the examples and properties, the
    /// triage and the run, each when `testReport` has it.
    static func summarySections(from testReport: MuterTestReport) -> Self {
        .group(
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
}
