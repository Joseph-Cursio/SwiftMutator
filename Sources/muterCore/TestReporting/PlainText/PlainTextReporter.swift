import Foundation

final class PlainTextReporter: Reporter {
    func report(from outcome: MutationTestOutcome) -> String {
        let report = MuterTestReport(from: outcome)
        let appliedMutationsMessage = """
        --------------------------
        Applied Mutation Operators
        --------------------------

        These are all of the ways that SwiftMutator introduced changes into your code.

        In total, SwiftMutator introduced \(report.totalAppliedMutationOperators) mutants in \(report.fileReports.count) files.

        \(generateAppliedMutationOperatorsCLITable(from: report.fileReports).description)


        """

        let coloredGlobalScore = coloredMutationScore(
            for: report.globalMutationScore,
            appliedTo: "\(report.globalMutationScore)%"
        )
        let projectCoverageMessage = coverageMessage(from: report)
        let mutationScoreMessage = "Mutation Score of Test Suite: ".bold + "\(coloredGlobalScore)"
        let mutationScoresMessage = """
        --------------------
        Mutation Test Scores
        --------------------

        SwiftMutator took \(report.timeElapsed) to run.

        These are the mutation scores for your test suite, as well as the files that had mutants introduced into them.

        Mutation scores ignore build errors.

        Of the \(
            report.totalAppliedMutationOperators
        ) mutants introduced into your code, your test suite killed \(
            report.numberOfKilledMutants
        ).
        \(mutationScoreMessage)\(suspectScoreLines(from: report))
        \(projectCoverageMessage)

        \(generateMutationScoresCLITable(from: report.fileReports).description)
        """

        return appliedMutationsMessage + killingTestsMessage(from: report) + mutationScoresMessage
    }

    /// The Killing Tests section, followed by the blank lines that end a section. None when no killed mutant has its
    /// tests recorded, so such a report is as it was.
    private func killingTestsMessage(from report: MuterTestReport) -> String {
        guard let summary = report.killingTestSummary else { return "" }
        // Without the line break CLITable ends each line with; none when there are no tests.
        let tableLines = generateKillingTestsCLITable(from: summary).description
            .split(separator: "\n")
            .map(String.init)
        let paragraphs: [String?] = [
            "-------------\nKilling Tests\n-------------",
            KillingTestSummary.introduction,
            summary.countSentences.joined(separator: "\n"),
            (tableLines + [summary.shownTestsSentence].compactMap { $0 }).joined(separator: "\n"),
            summary.noVerdictSentence,
            summary.suspectSentences(mutationScore: report.globalMutationScore).joined(separator: "\n"),
        ]
        return paragraphs.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n\n\n"
    }

    /// The score without suspect tests and which they are, each on a line of its own after the headline score, with
    /// prefixes scripts can look for. None when there are no suspects, so such a report is as it was.
    private func suspectScoreLines(from report: MuterTestReport) -> String {
        guard let summary = report.suspectSummary else { return "" }
        let score = summary.shownScoreWithoutSuspects(mutationScore: report.globalMutationScore)
        return "\nMutation Score without suspect tests: \(score)"
            + "\nSuspect tests: \(summary.suspects.count) (\(summary.suspectNames)); see Killing Tests above"
    }

    private func coverageMessage(from report: MuterTestReport) -> String {
        report.projectCodeCoverage.map { "Code Coverage of your project: \($0)%" }
            ?? "SwiftMutator could not gather coverage data from your project"
    }
}
