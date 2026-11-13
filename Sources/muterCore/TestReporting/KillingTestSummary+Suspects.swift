/// What every report says of suspect tests: the one warning, and the score without them. Never "killed" and a number.
extension KillingTestSummary {
    /// The suspect tests, those that failed for the most mutants first.
    var suspects: [Test] {
        tests.filter(\.suspect)
    }

    /// Which tests `isSuspectOnlyKill` takes as suspects.
    var suspectIdentities: Set<FailedTestLine.TestIdentity> {
        Set(suspects.map(\.identity))
    }

    /// Whether the score without suspect tests may be higher than it says: a kill only they were recorded failing
    /// for may not name every test that failed.
    var scoreWithoutSuspectsIsALowerBound: Bool {
        suspectOnlyKillsWithIncompleteLists > 0
    }

    /// The mutation score without suspect tests' failures, given the headline `mutationScore`.
    func scoreWithoutSuspects(mutationScore: Int) -> Int {
        mutationScoreWithoutSuspectOnlyKills ?? mutationScore
    }

    /// That score as the reports show it: "72%", or "at least 72%" when it is a lower bound.
    func shownScoreWithoutSuspects(mutationScore: Int) -> String {
        let score = scoreWithoutSuspects(mutationScore: mutationScore)
        return scoreWithoutSuspectsIsALowerBound ? "at least \(score)%" : "\(score)%"
    }

    /// The suspect tests' names: the first 3, then how many more.
    var suspectNames: String {
        Self.names(of: suspects) { $0.name }
    }

    /// The sentence every report warns of suspect tests with, given the headline `mutationScore`: which they are,
    /// why, and the score without them. nil when there are none.
    func warning(mutationScore: Int) -> String? {
        guard !suspects.isEmpty else { return nil }
        let (these, they) = suspects.count == 1 ? ("1 test", "it") : ("\(suspects.count) tests", "they")
        let flaky = suspects.filter { $0.failedControlRuns > 0 }
        let alone = suspects.filter { $0.isFlaky && $0.failedControlRuns == 0 }
        let byTheRule = suspects.filter { !$0.isFlaky }
        let notAgain = "didn't fail again often enough when tested alone (" + Self.names(of: alone) {
            "\($0.name) failed again in \($0.failedAgainAlone) of \($0.notReproducedAlone + $0.failedAgainAlone)"
        } + ")"
        let inControlRuns = "failed in a control run, with no mutant on "
            + "(\(Self.names(of: flaky) { "\($0.name) in \($0.failedControlRuns) of \(controlRuns)" }))"
        let forMutants = "for mutants in at least \(suspectFilePercent)% of the \(filesWithKills) files with a killed "
            + "mutant (\(Self.names(of: byTheRule) { "\($0.name) in \($0.files)" }))"
        let why = switch (flaky.isEmpty, alone.isEmpty, byTheRule.isEmpty) {
        case (true, true, _): "\(they) failed \(forMutants)"
        case (false, true, true): "\(they) \(inControlRuns)"
        case (true, false, true): "\(they) \(notAgain)"

        default:
            Self.listed([
                flaky.isEmpty ? nil : "\(flaky.count) \(inControlRuns)",
                alone.isEmpty ? nil : "\(alone.count) \(notAgain)",
                byTheRule.isEmpty ? nil : "\(byTheRule.count) failed \(forMutants)",
            ])
        }
        return "\(these) may fail whatever the mutant: \(why). " + scoreSentence(mutationScore: mutationScore)
    }

    /// The warning for `outcome`'s report.
    static func warning(for outcome: MutationTestOutcome) -> String? {
        KillingTestSummary(
            of: outcome.mutations, controlRuns: outcome.controlRuns, thresholds: outcome.suspectTestThresholds
        )?
            .warning(mutationScore: mutationScore(from: outcome.mutations.map(\.testSuiteOutcome)))
    }

    /// What the mutation score would be without the suspect tests' failures, against the headline `mutationScore`.
    func scoreSentence(mutationScore: Int) -> String {
        let their = suspects.count == 1 ? "its" : "their"
        let without = scoreWithoutSuspects(mutationScore: mutationScore)
        guard without != mutationScore else {
            return "Without \(their) failures, the mutation score would still be \(mutationScore)%."
        }
        return "Without \(their) failures, the mutation score would be "
            + "\(shownScoreWithoutSuspects(mutationScore: mutationScore)), not \(mutationScore)%."
    }

    /// `clauses` that aren't nil, in a sentence: "a, and b", or "a, b, and c".
    static func listed(_ clauses: [String?]) -> String {
        let present = clauses.compactMap(\.self)
        guard let last = present.last, present.count > 1 else { return present.joined() }
        return present.dropLast().joined(separator: ", ") + ", and " + last
    }

    /// The first 3 of `tests` as `describe` says them, then how many more.
    static func names<Named>(of tests: [Named], _ describe: (Named) -> String) -> String {
        let shown = tests.prefix(3).map(describe)
        return (tests.count > 3 ? shown + ["and \(tests.count - 3) more"] : shown).joined(separator: ", ")
    }

    /// The tests suspect by their reach or a control run, or that were flaky alone, whatever else they did alone. What
    /// a session chooses kills to test from, so that a chance failure alone in an earlier session can't cancel the
    /// rest.
    var suspectsWhateverTheyDidAlone: Set<FailedTestLine.TestIdentity> {
        Set(tests.filter { $0.suspect || $0.clearedAlone }.map(\.identity))
    }
}
