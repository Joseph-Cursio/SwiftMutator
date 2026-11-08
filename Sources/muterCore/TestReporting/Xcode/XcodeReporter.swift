struct XcodeReporter: Reporter {
    @Dependency(\.logger)
    private var logger: Logger

    func newMutationTestOutcomeAvailable(outcomeWithFlush: MutationOutcomeWithFlush) {
        let outcome = outcomeWithFlush.mutation

        guard [.passed, .noCoverage].contains(outcome.testSuiteOutcome) else {
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
        Mutants by outcome: \(OutcomeCounts(outcome.mutations.map(\.testSuiteOutcome)).tally)
        """
        // A warning without a file and line, which Xcode lists without a location: a mutant that was a build error has
        // no survivor's warning to show it wasn't tested.
        let buildErrors = [outcome.buildErrorWarning, outcome.unprovenKillWarning].compactMap { $0 }
            .map { "\nwarning: SwiftMutator: \($0)" }.joined()
        guard let suspects = report.suspectSummary, let warning = report.suspectWarning else {
            return summary + buildErrors
        }
        let scoreWithoutSuspects = suspects.scoreWithoutSuspects(mutationScore: report.globalMutationScore)
        // "at least" when it is a lower bound, as the other formats say; the score stays a bare number, as above.
        let atLeast = suspects.scoreWithoutSuspectsIsALowerBound ? "at least " : ""
        // A warning without a file and line, which Xcode lists without a location.
        return summary + """

        Mutation score without suspect tests: \(atLeast)\(scoreWithoutSuspects)
        warning: SwiftMutator: \(warning)
        """ + buildErrors
    }

    /// What a warning says of a mutant the tests didn't kill, which SARIF's results say too.
    static func verdict(of outcome: TestSuiteOutcome) -> String {
        outcome == .noCoverage ? "No test reached this mutant" : "Your test suite did not kill this mutant"
    }

    private func outcomeIntoXcodeString(outcome: MutationTestOutcome.Mutation) -> String {
        // {full_path_to_file}{:line}{:character}: {error,warning}: {content}

        "\(outcome.originalProjectPath):" +
            "\(outcome.point.position.line):\(outcome.point.position.column): " +
            "warning: \(Self.verdict(of: outcome.testSuiteOutcome)): \(outcome.snapshot.description)"
    }
}
