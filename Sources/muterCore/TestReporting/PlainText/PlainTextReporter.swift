import Foundation

struct PlainTextReporter: Reporter {
    func report(from outcome: MutationTestOutcome) -> String {
        let report = MuterTestReport(from: outcome)
        let survivorsMessage = """
        -----------------
        Surviving Mutants
        -----------------

        \(survivorLines(from: report).joined(separator: "\n"))


        """ + notCoveredMessage(from: report)
        let appliedMutationsMessage = """
        --------------------------
        Applied Mutation Operators
        --------------------------

        These are all of the ways that SwiftMutator introduced changes into your code.

        In total, SwiftMutator introduced \(report.totalAppliedMutationOperators) mutants in \(report.fileReports.count) files.

        \(generateAppliedMutationOperatorsCLITable(from: report.fileReports).description)\(
            operatorLegend(from: report)
        )


        """

        let coloredGlobalScore = coloredMutationScore(
            for: report.globalMutationScore,
            appliedTo: "\(report.globalMutationScore)%"
        )
        let projectCoverageMessage = Self.coverageMessage(from: report, skipped: outcome.coverageSkipped)
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
        By outcome: \(report.mutantsByOutcome?.tally ?? "")
        \(mutationScoreMessage)\(suspectScoreLines(from: report))
        \(projectCoverageMessage)\(report.since.map { "\n" + $0.sentence } ?? "")\(
            report.shards.map { "\n" + $0.sentence(sampled: report.sample != nil) } ?? ""
        )\(report.sample.map { "\n" + $0.sentence } ?? "")\(
            report.mutant.map { "\n" + MuterTestReport.oneMutantSentence($0) } ?? ""
        )

        \(generateMutationScoresCLITable(from: report.fileReports).description)
        """

        return survivorsMessage + appliedMutationsMessage + killingTestsMessage(from: report)
            + propertyKillsMessage(from: report) + triageMessage(from: report) + mutationScoresMessage
            + runMessage(from: report)
    }

    /// What each operator in the table does, after a blank line; none without mutants.
    private func operatorLegend(from report: MuterTestReport) -> String {
        guard let explanations = report.operatorExplanations else { return "" }
        let lines = explanations.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return "\nWhat these operators do:\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Where the results came from, after the scores; none when not known.
    private func runMessage(from report: MuterTestReport) -> String {
        guard let run = report.run else { return "" }
        return "\n\n\n---\nRun\n---\n\n" + run.lines.joined(separator: "\n")
    }

    /// The survivors, which are the mutants to act on, each at its place, then the line it changes, before and
    /// after, when its original file gives it. The place starts the line, so an editor or terminal can open it.
    private func survivorLines(from report: MuterTestReport) -> [String] {
        let survivors = report.survivors
        guard !survivors.isEmpty else { return ["No mutant survived or timed out."] }
        let lines = survivors.flatMap { survivor -> [String] in
            let mutant = survivor.appliedOperator
            let description = mutant.mutationSnapshot.description
            let change = description.isEmpty ? "" : " (\(description))"
            let verdict = MutantVerdict(mutant.testSuiteOutcome).words(1)
            let place = MuterTestReport.place(mutant, in: survivor.relativePath)
            return ["\(place) \(verdict): \(mutant.mutationPoint.mutationOperatorId.rawValue)\(change)"]
                + (mutant.sourceChange?.lines ?? []).map { "    " + $0 }
                + (mutant.triage.map { ["    Triaged: \($0.text)"] } ?? [])
        }
        return [Self.survivorsIntroduction(survivors.count), ""] + lines
    }

    /// The Mutants Not Covered section, followed by the blank lines that end a section. None when no mutant is not
    /// covered.
    private func notCoveredMessage(from report: MuterTestReport) -> String {
        let mutants = report.notCovered
        guard !mutants.isEmpty else { return "" }
        let lines = mutants.flatMap { item -> [String] in
            let mutant = item.appliedOperator
            let description = mutant.mutationSnapshot.description
            let change = description.isEmpty ? "" : " (\(description))"
            let place = MuterTestReport.place(mutant, in: item.relativePath)
            return ["\(place): \(mutant.mutationPoint.mutationOperatorId.rawValue)\(change)"]
                + (mutant.sourceChange?.lines ?? []).map { "    " + $0 }
                + (mutant.triage.map { ["    Triaged: \($0.text)"] } ?? [])
        }
        return """
        --------------------
        Mutants Not Covered
        --------------------

        \(Self.notCoveredIntroduction(mutants.count))

        \(lines.joined(separator: "\n"))


        """
    }

    /// "No test reached these 3 mutants: …": what the reports say of the mutants not covered.
    static func notCoveredIntroduction(_ count: Int) -> String {
        let (mutants, them) = count == 1 ? ("this mutant", "its") : ("these \(count) mutants", "their")
        return "No test reached \(mutants): your tests passed without running \(them) blocks, and the score counts "
            + "\(count == 1 ? "it" : "them") as not killed. By path, line and column:"
    }

    /// "These 3 mutants survived: your tests passed with each of them on, or ran out of time, which the score counts
    /// as surviving too. By path, line and column:"
    static func survivorsIntroduction(_ count: Int) -> String {
        let (these, them) = count == 1 ? ("This mutant", "it") : ("These \(count) mutants", "each of them")
        return "\(these) survived: your tests passed with \(them) on, or ran out of time, which the score counts as "
            + "surviving too. By path, line and column:"
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
            summary.controlRunSentences.joined(separator: "\n"),
            summary.testedAloneSentences.joined(separator: "\n"),
            summary.suspectSentences(mutationScore: report.globalMutationScore).joined(separator: "\n"),
        ]
        return paragraphs.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n\n\n"
    }

    /// The Examples and Properties section, followed by the blank lines that end a section. None without
    /// `propertyTests`, so such a report is as it was.
    private func propertyKillsMessage(from report: MuterTestReport) -> String {
        guard let summary = report.propertyKillSummary else { return "" }
        let tableLines = summary.properties.isEmpty ? [] : generatePropertyKillsCLITable(from: summary).description
            .split(separator: "\n")
            .map(String.init)
        let paragraphs: [String?] = [
            "-----------------------\nExamples and Properties\n-----------------------",
            PropertyKillSummary.introduction + " " + summary.globSentence,
            summary.splitSentences.joined(separator: "\n"),
            (tableLines + [summary.shownPropertiesSentence].compactMap { $0 }).joined(separator: "\n"),
        ]
        return paragraphs.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n\n\n"
    }

    /// The Triage section, followed by the blank lines that end a section. None without a triage file with entries, so
    /// such a report is as it was.
    private func triageMessage(from report: MuterTestReport) -> String {
        guard let summary = report.triageSummary else { return "" }
        let paragraphs: [String?] = [
            "------\nTriage\n------",
            TriageSummary.introduction,
            ([summary.countSentence] + [summary.labelSentence].compactMap { $0 }).joined(separator: "\n"),
        ] + summary.attentionParagraphs.map { $0.joined(separator: "\n") }
        return paragraphs.compactMap { $0 }.joined(separator: "\n\n") + "\n\n\n"
    }

    /// The score without suspect tests and which they are, each on a line of its own after the headline score, with
    /// prefixes scripts can look for. None when there are no suspects, so such a report is as it was.
    private func suspectScoreLines(from report: MuterTestReport) -> String {
        guard let summary = report.suspectSummary else { return "" }
        let score = summary.shownScoreWithoutSuspects(mutationScore: report.globalMutationScore)
        return "\nMutation Score without suspect tests: \(score)"
            + "\nSuspect tests: \(summary.suspects.count) (\(summary.suspectNames)); see Killing Tests above"
    }

    /// The project's coverage; without it, whether `--skip-coverage` skipped it or SwiftMutator failed to gather it.
    /// The Markdown report words it so too.
    static func coverageMessage(from report: MuterTestReport, skipped: Bool) -> String {
        if let coverage = report.projectCodeCoverage {
            return "Code Coverage of your project: \(coverage)%"
        }
        return skipped
            ? "Coverage skipped (--skip-coverage)"
            : "SwiftMutator could not gather coverage data from your project"
    }
}
