final class XcodeReporter: Reporter {
    @Dependency(\.logger)
    private var logger: Logger

    func newMutationTestOutcomeAvailable(outcomeWithFlush: MutationOutcomeWithFlush) {
        let outcome = outcomeWithFlush.mutation

        guard outcome.testSuiteOutcome == .passed else {
            return
        }

        logger.print(outcomeIntoXcodeString(outcome: outcome))

        outcomeWithFlush.fflush()
    }

    func report(from outcome: MutationTestOutcome) -> String {
        let report = MuterTestReport(from: outcome)
        let summary = """
        Mutation score: \(report.globalMutationScore)
        Mutants introduced into your code: \(report.totalAppliedMutationOperators)
        Number of killed mutants: \(report.numberOfKilledMutants)
        """
        guard let suspects = report.suspectSummary, let warning = report.suspectWarning else { return summary }
        let scoreWithoutSuspects = suspects.scoreWithoutSuspects(mutationScore: report.globalMutationScore)
        // "at least" when it is a lower bound, as the other formats say; the score stays a bare number, as above.
        let atLeast = suspects.scoreWithoutSuspectsIsALowerBound ? "at least " : ""
        // A warning without a file and line, which Xcode lists without a location.
        return summary + """

        Mutation score without suspect tests: \(atLeast)\(scoreWithoutSuspects)
        warning: SwiftMutator: \(warning)
        """
    }

    private func outcomeIntoXcodeString(outcome: MutationTestOutcome.Mutation) -> String {
        // {full_path_to_file}{:line}{:character}: {error,warning}: {content}

        "\(outcome.originalProjectPath):" +
            "\(outcome.point.position.line):\(outcome.point.position.column): " +
            "warning: " +
            "Your test suite did not kill this mutant: \(outcome.snapshot.description)"
    }
}
