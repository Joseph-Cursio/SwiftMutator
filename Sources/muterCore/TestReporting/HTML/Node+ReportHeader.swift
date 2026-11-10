import Foundation
import Plot

private extension Date {
    var string: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d yyyy HH:mm:ss"

        return formatter.string(from: self)
    }
}

/// The HTML report's frame: its header of boxes, theme toggle, summary, section dividers and footer.
extension Node where Context: HTML.BodyContext {
    /// The report's header: the logo, then a box for the score, the score without suspect tests, the coverage, the
    /// part of the project tested, and the operators applied.
    static func muterHeader(from testReport: MuterTestReport) -> Self {
        .header(
            .div(.class("logo"), .raw(muterLogo)),
            .headerItem(
                background: testReport.scoreColor,
                .p(.class("small"), "Mutation Score"),
                .h1("\(testReport.globalMutationScore)%")
            ),
            .unwrap(testReport.suspectSummary) { summary in
                .headerItem(
                    background: "#f39c12",
                    .p(
                        .class("small"),
                        .text(summary.scoreWithoutSuspectsIsALowerBound
                            ? "Without Suspect Tests, at least" : "Without Suspect Tests")
                    ),
                    .h1(.text("\(summary.scoreWithoutSuspects(mutationScore: testReport.globalMutationScore))%"))
                )
            },
            .unwrap(testReport.projectCodeCoverage) { coverage in
                .headerItem(
                    background: HTMLReporter.scoreColor(for: coverage),
                    .p(.class("small"), "Code Coverage"),
                    .h1("\(coverage)%")
                )
            },
            .scopeItems(of: testReport),
            .headerItem(
                background: "#3498db",
                .p(.class("small"), "Operators Applied"),
                .h1("\(testReport.totalAppliedMutationOperators)")
            )
        )
    }

    /// The header's boxes for the part of the project `testReport` covers: the code `--since` chose, the shards, the
    /// sample, or the one mutant; none for a whole run.
    static func scopeItems(of testReport: MuterTestReport) -> Self {
        .group(
            .unwrap(testReport.since) { since in
                .headerItem(
                    background: "#8e44ad",
                    .p(.class("small"), .text((since.changedLines ? "Lines" : "Files") + " changed since")),
                    .h1(.text(since.ref))
                )
            },
            .unwrap(testReport.shards) { shards in
                .headerItem(
                    background: "#8e44ad",
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
            },
            .unwrap(testReport.sample) { sample in
                .headerItem(
                    background: "#8e44ad",
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
            },
            .unwrap(testReport.mutant) { mutant in
                .headerItem(
                    background: "#8e44ad",
                    .p(.class("small"), .text(MuterTestReport.oneMutantSentence(mutant))),
                    .h1("One mutant")
                )
            }
        )
    }

    /// One of the header's boxes, on `background`: what it shows, under `label`.
    static func headerItem(background: String, _ label: Self, _ value: Self) -> Self {
        .div(
            .class("header-item"),
            .div(
                .class("box"),
                .style("background-color: \(background)"),
                label,
                value
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

    static func muterFooter(now: () -> Date) -> Self {
        .footer(
            .class("footer"),
            "\(now().string)"
        )
    }
}
