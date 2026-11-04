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
        /// Whether it may fail whatever the mutant: it failed for mutants in so many of the files (`isSuspect`), or in
        /// a control run.
        let suspect: Bool
    }

    /// A test that failed in a control run, with no mutant on, so is flaky, whether or not it failed for a mutant.
    struct FlakyTest: Codable, Equatable {
        let name: String
        /// As a `Test`'s.
        let file: String?
        /// How many control runs it failed in.
        let controlRuns: Int
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
    /// How many mutated files have a killed mutant that names a test: what `suspectFilePercent` is a share of.
    let filesWithKills: Int
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
    /// Every test that failed in a control run, those that failed in the most first, then by name and file.
    let flakyTests: [FlakyTest]

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
    /// The summary of `mutations`, whose suspect tests are those `thresholds` picks and those that failed in any of
    /// `controlRuns`: nil when no mutant a failed test killed has its tests recorded.
    init?(
        of mutations: [MutationTestOutcome.Mutation],
        controlRuns: [MutationTestOutcome.ControlRun] = [],
        thresholds: SuspectTestThresholds = .standard
    ) {
        let killed = mutations.filter { $0.testSuiteOutcome == .failed }
        let recorded = killed.compactMap { mutation in
            mutation.killingTests.map { (path: mutation.point.filePath, killing: $0) }
        }
        guard !recorded.isEmpty else { return nil }
        let failedControlRuns = controlRuns.filter { $0.outcome != .passed }
        var flaky: [FailedTestLine.TestIdentity: Int] = [:]
        for run in failedControlRuns {
            for identity in Set((run.failedTests?.tests ?? []).map(FailedTestLine.TestIdentity.init)) {
                flaky[identity, default: 0] += 1
            }
        }
        let named = recorded.filter { !$0.killing.tests.isEmpty }
        let filesWithKills = Set(named.map(\.path)).count

        var tallies: [FailedTestLine.TestIdentity: Tally] = [:]
        for (path, killing) in named {
            // Each test once for each mutant, however many of its lines a list holds.
            for identity in Set(killing.tests.map(FailedTestLine.TestIdentity.init)) {
                tallies[identity, default: Tally()].add(path)
            }
            if killing.count == 1, let only = killing.tests.first {
                tallies[.init(only), default: Tally()].onlyRecordedFailureOf += 1
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
                    thresholds: thresholds
                )
            }
            .sorted { ($1.mutants, $0.identity) < ($0.mutants, $1.identity) }

        let suspects = Set(ranked.filter(\.suspect).map(\.identity))
        let suspectOnly = mutations.map { Self.isSuspectOnlyKill($0, suspects: suspects) }
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
            suspectFilePercent: thresholds.filePercent,
            suspectMinimumFiles: thresholds.minimumFiles,
            suspectsChecked: filesWithKills >= thresholds.minimumFiles,
            distinctTests: ranked.count,
            tests: Array(ranked.prefix(Self.shownTests)) + ranked.dropFirst(Self.shownTests).filter(\.suspect),
            suspectOnlyKills: suspectOnlyKills.count,
            suspectOnlyKillsWithIncompleteLists: suspectOnlyKills.count { $0.killingTests?.isComplete == false },
            mutationScoreWithoutSuspectOnlyKills: suspectOnlyKills.isEmpty ? nil : scoreWithoutThem,
            controlRuns: controlRuns.count,
            failedControlRuns: failedControlRuns.count,
            failedControlRunsNamingNoTest: failedControlRuns.count { $0.failedTests?.tests.isEmpty != false },
            flakyTests: flaky
                .sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .map { FlakyTest(name: $0.key.name, file: $0.key.file, controlRuns: $0.value) }
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
            let files = filesWithKills == 1 ? "1 file" : "\(filesWithKills) files"
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
        return "Suspect tests are looked for once \(suspectMinimumFiles) files have a killed mutant that names a "
            + "test; this report has \(filesWithKills)."
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
        if !flakyTests.isEmpty {
            let named = Self.names(of: flakyTests) { "\($0.name) in \($0.controlRuns)" }
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

    /// What the section says of its suspect tests, given the headline `mutationScore`: why they are suspect, what
    /// the score would be without them, and how to leave one out. None when there are none.
    func suspectSentences(mutationScore: Int) -> [String] {
        guard !suspects.isEmpty else { return [] }
        let these = suspects.count == 1 ? "1 suspect test" : "\(suspects.count) suspect tests"
        let theirKills = switch suspectOnlyKills {
        case 0: "Another test was recorded failing for each mutant a suspect test failed for."
        case 1: "Only suspect tests were recorded failing for 1 mutant."
        default: "Only suspect tests were recorded failing for \(suspectOnlyKills) mutants."
        }
        let byTheRule = suspects.filter { $0.failedControlRuns == 0 }
        let flaky = suspects.count - byTheRule.count
        let why = if flaky == 0 {
            "\(these) failed for mutants in at least \(suspectFilePercent)% of the \(filesWithKills) files with a "
                + "killed mutant. A test of the mutated code rarely does that; a test that is timing-sensitive, or "
                + "flaky under load, does."
        } else if byTheRule.isEmpty {
            "\(these) failed in a control run, with no mutant on and under the same load, so may fail whatever the "
                + "mutant."
        } else {
            "Of \(these), \(flaky) failed in a control run, with no mutant on and under the same load, and "
                + "\(byTheRule.count) for mutants in at least \(suspectFilePercent)% of the \(filesWithKills) files "
                + "with a killed mutant, which a test of the mutated code rarely does."
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
        let byTheRule = suspects.filter { $0.failedControlRuns == 0 }
        let inControlRuns = "failed in a control run, with no mutant on "
            + "(\(Self.names(of: flaky) { "\($0.name) in \($0.failedControlRuns) of \(controlRuns)" }))"
        let forMutants = "for mutants in at least \(suspectFilePercent)% of the \(filesWithKills) files with a killed "
            + "mutant (\(Self.names(of: byTheRule) { "\($0.name) in \($0.files)" }))"
        let why = if flaky.isEmpty {
            "\(they) failed \(forMutants)"
        } else if byTheRule.isEmpty {
            "\(they) \(inControlRuns)"
        } else {
            "\(flaky.count) \(inControlRuns), and \(byTheRule.count) failed \(forMutants)"
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

    /// Its Suspect cell in the reports' tables: "flaky" when it failed in a control run, "yes" when it is suspect for
    /// the files it failed for mutants in, "-" otherwise.
    var suspectCell: String {
        failedControlRuns > 0 ? "flaky" : suspect ? "yes" : "-"
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
}

private extension KillingTestSummary.Test {
    init(
        _ identity: FailedTestLine.TestIdentity,
        _ tally: KillingTestSummary.Tally,
        filesWithKills: Int,
        failedControlRuns: Int,
        thresholds: SuspectTestThresholds
    ) {
        self.init(
            name: identity.name,
            file: identity.file,
            mutants: tally.mutants,
            files: tally.files.count,
            onlyRecordedFailureOf: tally.onlyRecordedFailureOf,
            failedControlRuns: failedControlRuns,
            suspect: failedControlRuns > 0 || KillingTestSummary.isSuspect(
                files: tally.files.count,
                filesWithKills: filesWithKills,
                thresholds: thresholds
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
    /// In fewer than 10 files, a focused test reaches 40%.
    static let standard = SuspectTestThresholds(filePercent: 15, minimumFiles: 10)
}
