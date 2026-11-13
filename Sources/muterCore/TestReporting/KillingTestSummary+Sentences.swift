/// What the plain and HTML reports' Killing Tests section says. Never "killed" and a number: scripts read the killed
/// count from the one line that says so.
extension KillingTestSummary {
    static let introduction =
        "These are the tests that failed for the most killed mutants. A mutant a crash killed isn't counted here."

    /// How many killed mutants name the tests that failed for them, and how many may not name them all, name none or
    /// have none recorded. Each in the singular when it is 1.
    var countSentences: [String] {
        let naming = killedMutants - killedMutantsNamingNoTest
        var sentences: [String] = []
        if naming > 0 {
            let (mutants, name, them) = naming == 1
                ? ("1 killed mutant", "names", "it") : ("\(naming) killed mutants", "name", "them")
            let filesLeft = filesWithKillsLeft ?? filesWithKills
            let files = filesLeft == 1 ? "1 file" : "\(filesLeft) files"
            sentences.append("\(mutants) \(name) the tests that failed for \(them), in \(files).")
        }
        if incompleteLists > 0 {
            let these = naming == 1 ? "It" : "\(incompleteLists) of them"
            let (their, name, they) = incompleteLists == 1 ? ("its", "names", "it") : ("their", "name", "they")
            sentences.append(
                "\(these) stopped at \(their) first failed test or \(their) time limit, or \(name) more than "
                    + "\(FailedTestLine.killedByLimit) tests, so \(they) may not name every test that failed."
            )
        }
        if killedMutantsNamingNoTest > 0 {
            // "more" only after the mutants that name a test.
            let more = naming > 0 ? " more" : ""
            let (mutants, name, theirLogs) = killedMutantsNamingNoTest == 1
                ? ("mutant", "names", "its log") : ("mutants", "name", "their logs")
            sentences.append(
                "\(killedMutantsNamingNoTest)\(more) killed \(mutants) \(name) no test, "
                    + "as no line of \(theirLogs) shows one failing."
            )
        }
        if killedMutantsNotRecorded > 0 {
            let mutants = killedMutantsNotRecorded == 1 ? "mutant" : "mutants"
            sentences.append(
                "The tests that failed for \(killedMutantsNotRecorded) more killed \(mutants) weren't recorded."
            )
        }
        return sentences
    }

    /// Says the list stops short of every test that failed, when it does.
    var shownTestsSentence: String? {
        guard distinctTests > tests.count else { return nil }
        return "These are \(tests.count) of the \(distinctTests) tests that failed. "
            + "The JSON report lists each mutant's."
    }

    /// Says why no test can be suspect, when too few files have a killed mutant that names a test.
    var noVerdictSentence: String? {
        guard !suspectsChecked else { return nil }
        return "Tests aren't judged by how many files they reach until \(suspectMinimumFiles) files have a killed "
            + "mutant that names a test; this report has \(filesWithKills)."
    }

    /// What the control runs came to, and the flaky tests that failed in them, each with how many: none without
    /// control runs.
    var controlRunSentences: [String] {
        guard controlRuns > 0 else { return [] }
        let runs = controlRuns == 1
            ? "The 1 control run" : failedControlRuns == 0 ? "All \(controlRuns) control runs"
            : "\(failedControlRuns) of the \(controlRuns) control runs"
        let didIt = failedControlRuns == 0 ? "passed" : "didn't pass"
        var sentences = ["\(runs), with no mutant on and under the same load as the mutants, \(didIt)."]
        let failedOne = flakyTests
            .filter { $0.controlRuns > 0 }
            .sorted { ($1.controlRuns, $0.identity) < ($0.controlRuns, $1.identity) }
        if !failedOne.isEmpty {
            let named = Self.names(of: failedOne) { "\($0.name) in \($0.controlRuns)" }
            sentences.append("A test that failed in one is flaky, so it is suspect: \(named).")
        }
        if failedControlRunsNamingNoTest > 0 {
            let all = failedControlRunsNamingNoTest == failedControlRuns
            let (these, name) = switch (all, failedControlRunsNamingNoTest == 1) {
            case (true, true): ("It", "names")
            case (true, false): ("They", "name")
            case (false, true): ("1 of them", "names")
            case (false, false): ("\(failedControlRunsNamingNoTest) of them", "name")
            }
            sentences.append("\(these) \(name) no failed test, as a crash or a timeout may not.")
        }
        return sentences
    }

    /// What testing kills again alone came to, and what it made of the tests: none without such a run.
    var testedAloneSentences: [String] {
        guard killsTestedAlone > 0 else { return [] }
        let kills = killsTestedAlone == 1 ? "1 killed mutant" : "\(killsTestedAlone) killed mutants"
        let was = killsTestedAlone == 1 ? "was" : "were"
        let came = switch (killsTestedAlone, killsThatSurvivedAlone) {
        case (1, 0): "It failed again or crashed, so it still counts as killed."
        case (1, _): "It no longer failed, so it counts as a survivor or not covered."
        case (_, 0): "Each failed again or crashed, so each still counts as killed."
        case (_, 1): "1 of them no longer failed, so it counts as a survivor or not covered."
        default: "\(killsThatSurvivedAlone) of them no longer failed, so they count as survivors or not covered."
        }
        var sentences = [
            "\(kills) that suspect tests failed for \(was) tested again, one at a time with no other mutant running, "
                + "to find out whether the failures come from the mutant or the tests. \(came)",
            "The table counts a mutant tested again as its first run had it, so it leaves out a test that failed only "
                + "when tested again.",
        ]
        let flaky = flakyTests.filter { $0.notReproducedAlone > 0 && $0.controlRuns == 0 }
        if !flaky.isEmpty {
            let named = Self.names(of: flaky) {
                "\($0.name) failed again in \($0.failedAgainAlone) of \($0.notReproducedAlone + $0.failedAgainAlone)"
            }
            sentences.append("A test that doesn't fail again often enough alone is flaky, so it is suspect: \(named).")
        }
        let cleared = tests.filter(\.clearedAlone)
        if !cleared.isEmpty {
            let named = Self.names(of: cleared) { "\($0.name) in \($0.failedAgainAlone)" }
            sentences.append(
                "A test that failed again every time alone isn't suspect, however far it reaches: \(named)."
            )
        }
        if suspectOnlyKillsNotTestedAlone > 0 {
            let (mutants, were, count) = suspectOnlyKillsNotTestedAlone == 1
                ? ("1 mutant", "wasn't", "counts") : ("\(suspectOnlyKillsNotTestedAlone) mutants", "weren't", "count")
            sentences.append(
                "\(mutants) only suspect tests failed for \(were) settled by this, and \(count) as killed on the first "
                    + "run's word: past suspectKillReruns, reused, or with a rerun that timed out or failed to build."
            )
        }
        return sentences
    }

    /// What the section says of its suspect tests, given the headline `mutationScore`: why they are suspect, what
    /// the score would be without them, and how to leave one out. None when there are none.
    func suspectSentences(mutationScore: Int) -> [String] {
        guard !suspects.isEmpty else { return [] }
        let these = suspects.count == 1 ? "1 suspect test" : "\(suspects.count) suspect tests"
        let theirKills = switch suspectOnlyKills {
        case 0 where killsThatSurvivedAlone > 0:
            "No mutant counts as killed only by suspect tests any more."

        case 0: "Another test was recorded failing for each mutant a suspect test failed for."
        case 1: "Only suspect tests were recorded failing for 1 mutant."
        default: "Only suspect tests were recorded failing for \(suspectOnlyKills) mutants."
        }
        let byTheRule = suspects.filter { !$0.isFlaky }
        let inControlRuns = suspects.filter { $0.failedControlRuns > 0 }
        let alone = suspects.filter { $0.isFlaky && $0.failedControlRuns == 0 }
        let why = switch (inControlRuns.isEmpty, alone.isEmpty, byTheRule.isEmpty) {
        case (true, true, _):
            "\(these) failed for mutants in at least \(suspectFilePercent)% of the \(filesWithKills) files with a "
                + "killed mutant. A test that is timing-sensitive, or flaky under load, does that, and so can a broad "
                + "test of the mutated code."

        case (false, true, true):
            "\(these) failed in a control run, with no mutant on and under the same load, so may fail whatever the "
                + "mutant."

        case (true, false, true):
            "\(these) didn't fail again often enough when tested alone, so may fail whatever the mutant."

        default:
            "Of \(these), " + Self.listed([
                inControlRuns.isEmpty ? nil : "\(inControlRuns.count) failed in a control run, with no mutant on and "
                    + "under the same load",
                alone.isEmpty ? nil : "\(alone.count) didn't fail again often enough when tested alone",
                byTheRule.isEmpty ? nil : "\(byTheRule.count) failed for mutants in at least \(suspectFilePercent)% of "
                    + "the \(filesWithKills) files with a killed mutant, as a flaky test or a broad test of the "
                    + "mutated code can",
            ]) + "."
        }
        var sentences = [why, theirKills + " " + scoreSentence(mutationScore: mutationScore)]
        if scoreWithoutSuspectsIsALowerBound {
            sentences.append(
                "Some of those runs stopped at their first failed test, so other tests may have failed too: the score "
                    + "without suspect tests is a lower bound, and the Only Recorded Failure Of counts may be high."
            )
        }
        sentences.append(
            byTheRule.isEmpty
                ? "Leave a flaky test out of mutation runs: skip it while the environment variable "
                + "\(isMuterRunningKey) is \(isMuterRunningValue), which SwiftMutator sets for the baseline, every "
                + "mutant's test run and the control runs."
                : "If a suspect test also fails without a mutant under the same load, leave it out of mutation runs: "
                + "skip it while the environment variable \(isMuterRunningKey) is \(isMuterRunningValue), which "
                + "SwiftMutator sets for the baseline and every mutant's test run."
        )
        return sentences
    }
}
