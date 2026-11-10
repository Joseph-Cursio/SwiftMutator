import Foundation

/// A short report in Markdown, for a GitHub job summary or a pull request's comment: the score, the verdicts of the
/// checks the run was asked for, the counts, the scores of up to `mostFiles` files, and the mutants to act on, up to
/// `mostListed` of each kind, as the JSON report lists them all. GitHub keeps at most 1 MiB of a step's summary. Every
/// line is made from the outcome alone, in the order the other reports give it, so two reports of one outcome are the
/// same.
struct MarkdownReporter: Reporter {
    /// How many surviving mutants the report names, and how many not covered.
    static let mostListed = 100
    /// How many files the scores by file name: every file no test ran has a row, in a run of a shard too, and a
    /// project of thousands would pass GitHub's limit with the table alone.
    static let mostFiles = 1_000

    func report(from outcome: MutationTestOutcome) -> String {
        let report = MuterTestReport(from: outcome)
        let blocks: [[String]] = [
            ["## Mutation testing"],
            headline(of: report, outcome),
            warnings(of: report, outcome),
            checks(of: outcome),
            [counts(of: report)].compactMap(\.self),
            scoresByFile(of: report),
            survivors(of: report),
            notCovered(of: report),
            [Self.coverageNote(of: report)].compactMap(\.self),
        ]
        return blocks.joined().joined(separator: "\n\n") + "\n"
    }

    /// The score in bold, the score without suspect tests, the coverage, and what part of the project was tested, as
    /// the plain report gives them, each a paragraph of its own.
    private func headline(of report: MuterTestReport, _ outcome: MutationTestOutcome) -> [String] {
        let withoutSuspects = report.suspectSummary.map { summary in
            "Mutation score without suspect tests: "
                + summary.shownScoreWithoutSuspects(mutationScore: report.globalMutationScore)
        }
        let lines: [String?] = [
            withoutSuspects,
            PlainTextReporter.coverageMessage(from: report, skipped: outcome.coverageSkipped),
            report.since?.sentence,
            report.shards?.sentence(sampled: report.sample != nil),
            report.sample?.sentence,
            report.mutant.map(MuterTestReport.oneMutantSentence),
        ]
        return ["**\(MarkdownText.plain(MuterTestReport.scoreLine(of: outcome)))**"]
            + lines.compactMap(\.self).map(MarkdownText.plain)
    }

    /// What the run warns of, each in a quote of its own: suspect tests, build errors, and kills whose code never ran.
    private func warnings(of report: MuterTestReport, _ outcome: MutationTestOutcome) -> [String] {
        [report.suspectWarning, outcome.buildErrorWarning, outcome.unprovenKillWarning]
            .compactMap(\.self)
            .map { "> ⚠️ " + MarkdownText.plain($0) }
    }

    /// The verdict of each check the run, or `report`, was asked for (`MutationTestOutcome.checks`), as the run's last
    /// lines say them, each a paragraph with ✅ when it passed, ❌ when it failed and ⚠️ when it wasn't checked: the
    /// score's against `--fail-under`, then the survivors' against `--baseline`'s file, with a table of the new
    /// survivors, the first `mostListed`, then the score's against the file's, then the doubtful kills', with a table
    /// of them, as many. None when no check was asked for, so such a report is as it was.
    private func checks(of outcome: MutationTestOutcome) -> [String] {
        guard let checks = outcome.checks else { return [] }
        var blocks: [String] = []
        if let gate = checks.scoreGate, let line = gate.line {
            blocks.append(gate.result.mark + " " + MarkdownText.plain(line))
        }
        if let check = checks.newSurvivors, let line = check.line {
            if let notice = check.versionNotice {
                blocks.append("⚠️ " + MarkdownText.plain(notice))
            }
            blocks.append(check.result.mark + " " + MarkdownText.plain(line))
            if case let .checked(comparison) = check.verdict {
                blocks += Self.table(
                    of: comparison.newSurvivors,
                    header: ["New survivor", "Change"]
                ) { survivor in
                    [
                        MarkdownText.codeInCell(survivor.mutant),
                        MarkdownText.codeInCell(survivor.before) + " → " + MarkdownText.codeInCell(survivor.after)
                            + (survivor.notCovered ? NewSurvivorsCheck.NewSurvivor.notCoveredNote : ""),
                    ]
                }
            }
        }
        if let check = checks.scoreDrop, let line = check.line {
            blocks.append(check.result.mark + " " + MarkdownText.plain(line))
        }
        if let check = checks.doubtfulKills, let line = check.line {
            blocks.append(check.result.mark + " " + MarkdownText.plain(line))
            blocks += Self.table(
                of: check.doubtfulKills,
                header: ["Doubtful kill", "Change", "Why"]
            ) { kill in
                [
                    MarkdownText.codeInCell(kill.mutant),
                    MarkdownText.codeInCell(kill.before) + " → " + MarkdownText.codeInCell(kill.after),
                    MarkdownText.plain(kill.why),
                ]
            }
        }
        guard !blocks.isEmpty else { return [] }
        return ["### Checks"] + blocks
    }

    /// A table of the first `mostListed` of `items`, a `row` each under `header`, then how many more; none without
    /// any.
    private static func table<Item>(of items: [Item], header: [String], row: (Item) -> [String]) -> [String] {
        guard !items.isEmpty else { return [] }
        let more = items.count - mostListed
        // The JSON report doesn't list them, and `report` saves a summary only with --summary.
        let rest = "…and \(more) more, which a run's summary.json lists, as `report`'s does with --summary."
        let alignments = Array(repeating: false, count: header.count)
        return [MarkdownText.table(header: header, alignments: alignments, rows: items.prefix(mostListed).map(row))]
            + (more > 0 ? [rest] : [])
    }

    /// One row of how many mutants came to each verdict some came to, and their total; none without mutants.
    private func counts(of report: MuterTestReport) -> String? {
        guard let counts = report.mutantsByOutcome, report.totalAppliedMutationOperators > 0 else { return nil }
        let verdicts = MutantVerdict.allCases.filter { counts.count(of: $0) > 0 }
        let header = verdicts.map { verdict in
            let words = verdict.words(2)
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        return MarkdownText.table(
            header: header + ["Total"],
            alignments: Array(repeating: true, count: verdicts.count + 1),
            rows: [verdicts.map { "\(counts.count(of: $0))" } + ["\(report.totalAppliedMutationOperators)"]]
        )
    }

    /// Each file's mutants and score, by path, the files with mutants first; a file no test ran, which has none, says
    /// so. The first `mostFiles`, then how many more there are.
    private func scoresByFile(of report: MuterTestReport) -> [String] {
        guard !report.fileReports.isEmpty else { return [] }
        let rows = report.fileReports.prefix(Self.mostFiles).map { file -> [String] in
            let path = MarkdownText.codeInCell(file.relativePath)
            let skipped = file.appliedOperators.allSatisfy { $0.testSuiteOutcome == .noCoverage && $0.key == nil }
            guard !skipped else { return [path, "0", TestSuiteOutcome.noCoverage.asMutationTestOutcome] }
            let score = file.mutationScore < 0 ? "none" : "\(file.mutationScore)%"
            return [path, "\(file.appliedOperators.count)", score]
        }
        let more = report.fileReports.count - Self.mostFiles
        return [
            "### Scores by file",
            MarkdownText.table(header: ["File", "Mutants", "Score"], alignments: [false, true, true], rows: rows),
        ] + (more > 0 ? ["…and \(more) more files; the JSON report lists them all."] : [])
    }

    private func survivors(of report: MuterTestReport) -> [String] {
        let survivors = report.survivors
        return ["### Surviving mutants (\(survivors.count))"]
            + (survivors.isEmpty ? ["No mutant survived or timed out."] : Self.listed(survivors))
    }

    /// What the plain and HTML reports say of them, then the list.
    private func notCovered(of report: MuterTestReport) -> [String] {
        let mutants = report.notCovered
        guard !mutants.isEmpty else { return [] }
        return [
            "### Mutants not covered (\(mutants.count))",
            MarkdownText.plain(PlainTextReporter.notCoveredIntroduction(mutants.count)),
        ] + Self.listed(mutants)
    }

    /// The first `mostListed` of `mutants`, grouped by file, each by its place in it, its operator and what it
    /// changes, whether it timed out, and its triage label; then how many more there are.
    private static func listed(
        _ mutants: [(relativePath: String, appliedOperator: AppliedMutationOperator)]
    ) -> [String] {
        var lines: [String] = []
        var file: String?
        for mutant in mutants.prefix(mostListed) {
            if mutant.relativePath != file {
                file = mutant.relativePath
                lines.append("- " + MarkdownText.code(mutant.relativePath))
            }
            lines.append("  - " + line(of: mutant.appliedOperator))
        }
        let more = mutants.count - mostListed
        return [lines.joined(separator: "\n")]
            + (more > 0 ? ["…and \(more) more; the JSON report lists them all."] : [])
    }

    /// "`42:17` RelationalOperatorReplacement: changed == to != (timed out) — Triaged: equivalent".
    private static func line(of mutant: AppliedMutationOperator) -> String {
        let position = mutant.mutationPoint.position
        let description = mutant.mutationSnapshot.description
        let change = description.isEmpty ? "" : ": " + MarkdownText.plain(description)
        let timedOut = mutant.testSuiteOutcome == .timeout ? " (timed out)" : ""
        let triage = mutant.triage.map { " — Triaged: " + MarkdownText.plain($0.text) } ?? ""
        return MarkdownText.code("\(position.line):\(position.column)") + " "
            + MarkdownText.plain(mutant.mutationPoint.mutationOperatorId.rawValue) + change + timedOut + triage
    }

    /// What the coverage run leaves out, which no count here has; none when coverage wasn't gathered, as then every
    /// mutant was made. It isn't what "not covered" counts: those mutants were made, and their own tests didn't run
    /// their blocks.
    static func coverageNote(of report: MuterTestReport) -> String? {
        guard report.projectCodeCoverage != nil else { return nil }
        return "With coverage on, no mutant is made in code the coverage run says no test ran, so no count here has "
            + "one: a file left out for its coverage (`coverageThreshold`) is one row, and a file the coverage data "
            + "doesn't name has none. \"Not covered\" counts only mutants that were made and tested, whose blocks "
            + "their tests didn't run. `--skip-coverage` makes them all."
    }
}
