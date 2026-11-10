/// Which tests failed for the most killed mutants, and which look as if they fail whatever the mutant. Counts only
/// mutants a failed test killed (`.failed`) with their tests recorded: a crash kills a mutant whatever failed.
struct KillingTestSummary: Codable, Equatable {
    /// How many tests the reports list, before any other suspect test.
    static let shownTests = 10

    struct Test: Codable, Equatable {
        let name: String
        /// The file its issues were recorded in, which with the name tells it apart (`FailedTestLine.TestIdentity`).
        /// None for XCTest's, whose lines give no location.
        let file: String?
        /// How many killed mutants it failed for.
        let mutants: Int
        /// How many mutated files those mutants are in.
        let files: Int
        /// How many of those mutants recorded it as the only test that failed.
        let onlyRecordedFailureOf: Int
        /// How many control runs, with no mutant on, it failed in: one or more makes it flaky.
        let failedControlRuns: Int
        /// Whether it may fail whatever the mutant (`isSuspect(reachesEnoughFiles:…)`).
        let suspect: Bool
        /// When a mutant it failed for was tested again alone: how many times it failed again, and how many it didn't,
        /// or failed with the mutant's code not running (`MutantResult.TestAlone`).
        var failedAgainAlone = 0
        var notReproducedAlone = 0
        /// Whether those runs took it off the suspect tests, though it failed for mutants in enough files.
        var clearedAlone = false
    }

    /// A test that failed in a control run, with no mutant on, so is flaky, whether or not it failed for a mutant.
    struct FlakyTest: Codable, Equatable {
        let name: String
        /// As a `Test`'s.
        let file: String?
        /// How many control runs it failed in.
        let controlRuns: Int
        /// As a `Test`'s: a test flaky for what it did alone may have failed in no control run.
        var failedAgainAlone = 0
        var notReproducedAlone = 0
    }

    /// Mutants a failed test killed whose tests were recorded, even as none.
    let killedMutants: Int
    /// Of those, how many name no test.
    let killedMutantsNamingNoTest: Int
    /// Mutants a failed test killed with no tests recorded.
    let killedMutantsNotRecorded: Int
    /// Mutants naming tests that may not name every test that failed: their run stopped at its first failed test or
    /// its time limit, or more failed than a list holds.
    let incompleteLists: Int
    /// How many mutated files have a mutant whose first run a failed test that it names killed: what
    /// `suspectFilePercent` is a share of.
    let filesWithKills: Int
    /// How many have a killed mutant that names a test now, when kills that no longer failed alone leave fewer.
    var filesWithKillsLeft: Int?
    /// The share of `filesWithKills` a test must have failed for mutants in to be suspect, and how many files with a
    /// kill there must be before any test can be (`SuspectTestThresholds`).
    let suspectFilePercent: Int
    let suspectMinimumFiles: Int
    /// Whether enough files have one for a test to be suspect (`suspectMinimumFiles`).
    let suspectsChecked: Bool
    /// How many tests failed for those mutants.
    let distinctTests: Int
    /// The `shownTests` that failed for the most mutants, then by name and file; then every other suspect test.
    let tests: [Test]
    /// Killed mutants only suspect tests were recorded failing for (`isSuspectOnlyKill`).
    let suspectOnlyKills: Int
    /// Of those, how many may not name every test that failed, so that another may have killed them.
    let suspectOnlyKillsWithIncompleteLists: Int
    /// The mutation score with those mutants counted as survivors, over the headline's mutants and truncated as it
    /// is. nil when there are none, as it is then the headline score.
    let mutationScoreWithoutSuspectOnlyKills: Int?
    /// How many control runs, with no mutant on, there were, and how many didn't pass: those that failed, crashed or
    /// timed out, of which `failedControlRunsNamingNoTest` named no failed test.
    let controlRuns: Int
    let failedControlRuns: Int
    let failedControlRunsNamingNoTest: Int
    /// Every test that failed in a control run, or didn't fail again often enough alone (`isFlakyAlone`), those with
    /// the most such runs first, then by name and file.
    let flakyTests: [FlakyTest]
    /// How many killed mutants were tested again alone, of this run's own, and how many of them no longer failed, so
    /// count as survivors or not covered.
    var killsTestedAlone = 0
    var killsThatSurvivedAlone = 0
    /// Of `suspectOnlyKills`, how many weren't tested again alone, so count as kills on the first run's word.
    var suspectOnlyKillsNotTestedAlone = 0

    /// Whether a test that failed for mutants in `files` of the `filesWithKills` files is suspect under `thresholds`.
    /// Integer arithmetic, so a run and its `report` always agree.
    static func isSuspect(
        files: Int,
        filesWithKills: Int,
        thresholds: SuspectTestThresholds = .standard
    ) -> Bool {
        filesWithKills >= thresholds.minimumFiles && files >= thresholds.minimumFiles
            && files * 100 >= thresholds.filePercent * filesWithKills
    }

    /// How many times a test must fail again alone, and never not, to be cleared. A kill it really makes always fails
    /// again, while a test that fails 30% of the time whatever the mutant passes three times in only 2.7% of cases.
    static let failuresAloneThatClearATest = 3
    /// How many times a test must fail again alone for each time it didn't, for that time to count as chance. Less, and
    /// it is flaky: one that often fails with no mutant to blame wouldn't pass a baseline at much above this.
    static let failuresAlonePerExemption = 4

    /// Whether what a test did alone shows that it fails whatever the mutant.
    static func isFlakyAlone(failedAgain: Int, notReproduced: Int) -> Bool {
        notReproduced > 0 && failedAgain < failuresAlonePerExemption * notReproduced
    }

    /// Whether what a test did alone shows that the mutants it failed for made it fail.
    static func isClearedAlone(failedAgain: Int, notReproduced: Int) -> Bool {
        failedAgain >= failuresAloneThatClearATest && notReproduced == 0
    }

    /// Whether a test may fail whatever the mutant: it failed in a control run, it didn't fail again often enough
    /// alone, or it reaches enough files, which what it did alone can clear. Nothing clears a failed control run.
    static func isSuspect(
        reachesEnoughFiles: Bool,
        failedControlRuns: Int,
        failedAgainAlone: Int,
        notReproducedAlone: Int
    ) -> Bool {
        failedControlRuns > 0
            || isFlakyAlone(failedAgain: failedAgainAlone, notReproduced: notReproducedAlone)
            || reachesEnoughFiles && !isClearedAlone(failedAgain: failedAgainAlone, notReproduced: notReproducedAlone)
    }

    /// Whether `mutation` is a kill only `suspects` were recorded failing for. Its list must name a test: one that
    /// names none would otherwise name only suspects. A crash kills a mutant whatever failed, so stays a kill.
    static func isSuspectOnlyKill(
        _ mutation: MutationTestOutcome.Mutation,
        suspects: Set<FailedTestLine.TestIdentity>
    ) -> Bool {
        guard mutation.testSuiteOutcome == .failed, let killing = mutation.killingTests, !killing.tests.isEmpty else {
            return false
        }
        return killing.tests.allSatisfy { suspects.contains(.init($0)) }
    }
}

extension KillingTestSummary {
    /// The summary of `mutations`, whose suspect tests are those `thresholds` picks, those that failed in any of
    /// `controlRuns`, and those a kill tested again alone shows to be flaky, less those it clears: nil when no mutant a
    /// failed test killed has its tests recorded, in its first run or since.
    ///
    /// How far a test reaches is measured on first runs alone. A kill tested again alone may be a survivor now, and its
    /// list runs to the end where its first run's stopped, so counting those would let reruns change which tests are
    /// suspect, and so which kills are tested, for reasons that have nothing to do with the tests.
    init?(
        of mutations: [MutationTestOutcome.Mutation],
        controlRuns: [MutationTestOutcome.ControlRun] = [],
        thresholds: SuspectTestThresholds = .standard
    ) {
        let killed = mutations.filter { $0.testSuiteOutcome == .failed }
        let recorded = killed.compactMap { mutation in
            mutation.killingTests.map { (path: mutation.point.filePath, killing: $0) }
        }
        let firstRuns: [FirstRun] = mutations.compactMap { mutation in
            let killing = mutation.testSuiteOutcome == .failed ? mutation.killingTests : nil
            let only = killing.flatMap { $0.count == 1 ? $0.tests.first.map(FailedTestLine.TestIdentity.init) : nil }
            if let alone = mutation.rerun?.alone {
                // A kill still failing says which test failed alone, which a list that stopped at its first can't.
                let onlyFirst = alone.count == 1 ? alone.first?.identity : nil
                return FirstRun(
                    path: mutation.point.filePath,
                    tests: alone.map(\.identity),
                    onlyFailure: killing == nil ? onlyFirst : only
                )
            }
            guard let killing, !killing.tests.isEmpty else { return nil }
            return FirstRun(
                path: mutation.point.filePath,
                tests: killing.tests.map(FailedTestLine.TestIdentity.init),
                onlyFailure: only
            )
        }
        guard !recorded.isEmpty || !firstRuns.isEmpty else { return nil }
        let failedControlRuns = controlRuns.filter { $0.outcome != .passed }
        var flaky: [FailedTestLine.TestIdentity: Int] = [:]
        for run in failedControlRuns {
            for identity in Set((run.failedTests?.tests ?? []).map(FailedTestLine.TestIdentity.init)) {
                flaky[identity, default: 0] += 1
            }
        }
        let named = recorded.filter { !$0.killing.tests.isEmpty }
        let filesWithKills = Set(firstRuns.map(\.path)).count
        let filesWithKillsLeft = Set(named.map(\.path)).count

        var tallies: [FailedTestLine.TestIdentity: Tally] = [:]
        for first in firstRuns {
            // Each test once for each mutant, however many of its lines a list holds.
            for identity in Set(first.tests) {
                tallies[identity, default: Tally()].add(first.path)
            }
            if let only = first.onlyFailure {
                tallies[only, default: Tally()].onlyRecordedFailureOf += 1
            }
        }
        var evidence: [FailedTestLine.TestIdentity: Evidence] = [:]
        for test in mutations.flatMap({ $0.rerun?.alone ?? [] }) {
            switch test.result {
            case MutantResult.TestAlone.failedAgain:
                evidence[test.identity, default: Evidence()].failedAgain += 1

            case MutantResult.TestAlone.passed, MutantResult.TestAlone.failedWithItsCodeNotRunning:
                evidence[test.identity, default: Evidence()].notReproduced += 1

            default:
                // None, or one a later SwiftMutator added, which says nothing this one can read.
                break
            }
        }
        // A total order, so every report lists the same tests the same way.
        let ranked = tallies
            .map { identity, tally in
                Test(
                    identity,
                    tally,
                    filesWithKills: filesWithKills,
                    failedControlRuns: flaky[identity] ?? 0,
                    evidence: evidence[identity] ?? Evidence(),
                    thresholds: thresholds
                )
            }
            .sorted { ($1.mutants, $0.identity) < ($0.mutants, $1.identity) }

        let suspects = Set(ranked.filter(\.suspect).map(\.identity))
        let suspectOnly = mutations.map { Self.isSuspectOnlyKill($0, suspects: suspects) }
        let testedAlone = mutations.filter(\.wasTestedAlone)
        let suspectOnlyKills = zip(mutations, suspectOnly).filter(\.1).map(\.0)
        // Counted as survivors, the headline's way.
        let scoreWithoutThem = mutationScore(
            from: zip(mutations, suspectOnly).map { mutation, isSuspectOnly in
                isSuspectOnly ? .passed : mutation.testSuiteOutcome
            }
        )

        self.init(
            killedMutants: recorded.count,
            killedMutantsNamingNoTest: recorded.count - named.count,
            killedMutantsNotRecorded: killed.count - recorded.count,
            incompleteLists: named.count { !$0.killing.isComplete },
            filesWithKills: filesWithKills,
            filesWithKillsLeft: filesWithKillsLeft < filesWithKills ? filesWithKillsLeft : nil,
            suspectFilePercent: thresholds.filePercent,
            suspectMinimumFiles: thresholds.minimumFiles,
            suspectsChecked: filesWithKills >= thresholds.minimumFiles,
            distinctTests: ranked.count,
            tests: Array(ranked.prefix(Self.shownTests))
                + ranked.dropFirst(Self.shownTests).filter { $0.suspect || $0.clearedAlone },
            suspectOnlyKills: suspectOnlyKills.count,
            suspectOnlyKillsWithIncompleteLists: suspectOnlyKills.count { $0.killingTests?.isComplete == false },
            mutationScoreWithoutSuspectOnlyKills: suspectOnlyKills.isEmpty ? nil : scoreWithoutThem,
            controlRuns: controlRuns.count,
            failedControlRuns: failedControlRuns.count,
            failedControlRunsNamingNoTest: failedControlRuns.count { $0.failedTests?.tests.isEmpty != false },
            flakyTests: Set(flaky.keys).union(ranked.filter(\.isFlaky).map(\.identity))
                .map { identity in
                    FlakyTest(
                        name: identity.name,
                        file: identity.file,
                        controlRuns: flaky[identity] ?? 0,
                        failedAgainAlone: evidence[identity]?.failedAgain ?? 0,
                        notReproducedAlone: evidence[identity]?.notReproduced ?? 0
                    )
                }
                .sorted { lhs, rhs in
                    (rhs.controlRuns + rhs.notReproducedAlone, lhs.identity)
                        < (lhs.controlRuns + lhs.notReproducedAlone, rhs.identity)
                },
            killsTestedAlone: testedAlone.count,
            killsThatSurvivedAlone: testedAlone.count { [.passed, .noCoverage].contains($0.testSuiteOutcome) },
            suspectOnlyKillsNotTestedAlone: suspectOnlyKills.count { !$0.wasTestedAlone }
        )
    }
}

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
    private func scoreSentence(mutationScore: Int) -> String {
        let their = suspects.count == 1 ? "its" : "their"
        let without = scoreWithoutSuspects(mutationScore: mutationScore)
        guard without != mutationScore else {
            return "Without \(their) failures, the mutation score would still be \(mutationScore)%."
        }
        return "Without \(their) failures, the mutation score would be "
            + "\(shownScoreWithoutSuspects(mutationScore: mutationScore)), not \(mutationScore)%."
    }

    /// `clauses` that aren't nil, in a sentence: "a, and b", or "a, b, and c".
    private static func listed(_ clauses: [String?]) -> String {
        let present = clauses.compactMap(\.self)
        guard let last = present.last, present.count > 1 else { return present.joined() }
        return present.dropLast().joined(separator: ", ") + ", and " + last
    }

    /// The first 3 of `tests` as `describe` says them, then how many more.
    private static func names<Named>(of tests: [Named], _ describe: (Named) -> String) -> String {
        let shown = tests.prefix(3).map(describe)
        return (tests.count > 3 ? shown + ["and \(tests.count - 3) more"] : shown).joined(separator: ", ")
    }
}

extension KillingTestSummary.Test {
    /// Which test it is, as each mutant's list tells them apart.
    var identity: FailedTestLine.TestIdentity {
        .init(name: name, file: file)
    }

    /// Whether it fails whatever the mutant, as a control run or what it did alone shows.
    var isFlaky: Bool {
        failedControlRuns > 0
            || KillingTestSummary.isFlakyAlone(failedAgain: failedAgainAlone, notReproduced: notReproducedAlone)
    }

    /// Its Suspect cell in the reports' tables: "flaky" when a control run or what it did alone shows it is, "yes" when
    /// it is suspect for the files it failed for mutants in, "cleared" when it would be but failed again every time
    /// alone, "-" otherwise.
    var suspectCell: String {
        isFlaky ? "flaky" : suspect ? "yes" : clearedAlone ? "cleared" : "-"
    }
}

extension KillingTestSummary.FlakyTest {
    /// Which test it is, as each mutant's list tells them apart.
    var identity: FailedTestLine.TestIdentity {
        .init(name: name, file: file)
    }
}

extension KillingTestSummary {
    /// The tests suspect by their reach or a control run, or that were flaky alone, whatever else they did alone. What
    /// a session chooses kills to test from, so that a chance failure alone in an earlier session can't cancel the
    /// rest.
    var suspectsWhateverTheyDidAlone: Set<FailedTestLine.TestIdentity> {
        Set(tests.filter { $0.suspect || $0.clearedAlone }.map(\.identity))
    }
}

extension MutationTestOutcome.Mutation {
    /// Whether this run tested it again alone, not a run it was reused from.
    var wasTestedAlone: Bool {
        rerun?.because == MutantResult.Rerun.onlySuspectTestsFailed && reusedFrom == nil
    }
}

private extension KillingTestSummary {
    /// The mutants a test failed for, as they're counted.
    struct Tally {
        var mutants = 0
        var files: Set<FilePath> = []
        var onlyRecordedFailureOf = 0

        mutating func add(_ path: FilePath) {
            mutants += 1
            files.insert(path)
        }
    }

    /// What failed in a mutant's first run.
    struct FirstRun {
        let path: FilePath
        let tests: [FailedTestLine.TestIdentity]
        /// The test recorded as the only one that failed for it.
        let onlyFailure: FailedTestLine.TestIdentity?
    }

    /// What a test did when mutants it failed for were tested again alone.
    struct Evidence {
        var failedAgain = 0
        var notReproduced = 0
    }
}

private extension KillingTestSummary.Test {
    init(
        _ identity: FailedTestLine.TestIdentity,
        _ tally: KillingTestSummary.Tally,
        filesWithKills: Int,
        failedControlRuns: Int,
        evidence: KillingTestSummary.Evidence,
        thresholds: SuspectTestThresholds
    ) {
        let reachesEnoughFiles = KillingTestSummary.isSuspect(
            files: tally.files.count,
            filesWithKills: filesWithKills,
            thresholds: thresholds
        )
        self.init(
            name: identity.name,
            file: identity.file,
            mutants: tally.mutants,
            files: tally.files.count,
            onlyRecordedFailureOf: tally.onlyRecordedFailureOf,
            failedControlRuns: failedControlRuns,
            suspect: KillingTestSummary.isSuspect(
                reachesEnoughFiles: reachesEnoughFiles,
                failedControlRuns: failedControlRuns,
                failedAgainAlone: evidence.failedAgain,
                notReproducedAlone: evidence.notReproduced
            ),
            failedAgainAlone: evidence.failedAgain,
            notReproducedAlone: evidence.notReproduced,
            clearedAlone: reachesEnoughFiles && failedControlRuns == 0
                && KillingTestSummary.isClearedAlone(
                    failedAgain: evidence.failedAgain,
                    notReproduced: evidence.notReproduced
                )
        )
    }
}

/// When a test is suspect: when it failed for mutants in at least `filePercent` of the files with a killed mutant that
/// names a test, and in at least `minimumFiles` of them, which there must be at least that many of. The configuration
/// keys `suspectTestFilePercent` and `suspectTestMinimumFiles` set them for a run, whose header records them, so its
/// `report` agrees with it.
struct SuspectTestThresholds: Equatable {
    /// From 1 to 100.
    let filePercent: Int
    /// At least 1.
    let minimumFiles: Int

    /// Measured on SwiftProjectLint's runs (killers-lab, 2026-10-06): no good test reached 15% of those files, in
    /// whole runs or in 1,634 smaller sub-runs (8.8% at most), while the tests that failed under load reached 23–97%.
    /// In fewer than 10 files, a focused test reaches 40%. That doesn't hold on a smaller project: on 2026-11-06 good
    /// tests reached 37% of SwiftCloneDetector's 30 files and 42% of SwiftEffectInference's 19. So the rule says only
    /// which kills to test again alone, which is what settles it (`isSuspect(reachesEnoughFiles:…)`).
    static let standard = Self(filePercent: 15, minimumFiles: 10)
}
