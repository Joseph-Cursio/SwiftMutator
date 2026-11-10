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
        let firstRuns = mutations.compactMap(Self.firstRun(of:))
        guard !recorded.isEmpty || !firstRuns.isEmpty else { return nil }
        let failedControlRuns = controlRuns.filter { $0.outcome != .passed }
        let flaky = Self.failures(in: failedControlRuns)
        let named = recorded.filter { !$0.killing.tests.isEmpty }
        let filesWithKills = Set(firstRuns.map(\.path)).count
        let filesWithKillsLeft = Set(named.map(\.path)).count

        let evidence = Self.evidence(from: mutations)
        let ranked = Self.ranked(
            Self.tallies(of: firstRuns),
            filesWithKills: filesWithKills,
            controlRunFailures: flaky,
            evidence: evidence,
            thresholds: thresholds
        )

        let suspects = Set(ranked.filter(\.suspect).map(\.identity))
        let suspectOnly = mutations.map { Self.isSuspectOnlyKill($0, suspects: suspects) }
        let testedAlone = mutations.filter(\.wasTestedAlone)
        let suspectOnlyKills = zip(mutations, suspectOnly).filter(\.1).map(\.0)
        let scoreWithoutThem = Self.score(of: mutations, without: suspectOnly)

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
            flakyTests: Self.flakyTests(ranked: ranked, controlRunFailures: flaky, evidence: evidence),
            killsTestedAlone: testedAlone.count,
            killsThatSurvivedAlone: testedAlone.count { [.passed, .noCoverage].contains($0.testSuiteOutcome) },
            suspectOnlyKillsNotTestedAlone: suspectOnlyKills.count { !$0.wasTestedAlone }
        )
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

    /// What failed in `mutation`'s first run, or alone when it was tested again alone: nil when no failed test killed
    /// it with its tests recorded.
    static func firstRun(of mutation: MutationTestOutcome.Mutation) -> FirstRun? {
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

    /// How many of `failedControlRuns` each test failed in.
    static func failures(
        in failedControlRuns: [MutationTestOutcome.ControlRun]
    ) -> [FailedTestLine.TestIdentity: Int] {
        var flaky: [FailedTestLine.TestIdentity: Int] = [:]
        for run in failedControlRuns {
            for identity in Set((run.failedTests?.tests ?? []).map(FailedTestLine.TestIdentity.init)) {
                flaky[identity, default: 0] += 1
            }
        }
        return flaky
    }

    /// The mutants each test failed for in `firstRuns`.
    static func tallies(of firstRuns: [FirstRun]) -> [FailedTestLine.TestIdentity: Tally] {
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
        return tallies
    }

    /// What each test did when kills it failed for were tested again alone.
    static func evidence(from mutations: [MutationTestOutcome.Mutation]) -> [FailedTestLine.TestIdentity: Evidence] {
        var evidence: [FailedTestLine.TestIdentity: Evidence] = [:]
        for test in mutations.flatMap({ $0.rerun?.alone ?? [] }) {
            switch test.result {
            case MutantResult.Rerun.TestAlone.failedAgain:
                evidence[test.identity, default: Evidence()].failedAgain += 1

            case MutantResult.Rerun.TestAlone.passed, MutantResult.Rerun.TestAlone.failedWithItsCodeNotRunning:
                evidence[test.identity, default: Evidence()].notReproduced += 1

            default:
                // None, or one a later SwiftMutator added, which says nothing this one can read.
                break
            }
        }
        return evidence
    }

    /// The tests `tallies` counts, those that failed for the most mutants first, in a total order, so every report
    /// lists the same tests the same way.
    static func ranked(
        _ tallies: [FailedTestLine.TestIdentity: Tally],
        filesWithKills: Int,
        controlRunFailures flaky: [FailedTestLine.TestIdentity: Int],
        evidence: [FailedTestLine.TestIdentity: Evidence],
        thresholds: SuspectTestThresholds
    ) -> [Test] {
        tallies
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
    }

    /// The mutation score of `mutations` with those `leftOut` marks counted as survivors, the headline's way.
    static func score(of mutations: [MutationTestOutcome.Mutation], without leftOut: [Bool]) -> Int {
        mutationScore(
            from: zip(mutations, leftOut).map { mutation, isLeftOut in
                isLeftOut ? .passed : mutation.testSuiteOutcome
            }
        )
    }

    /// The tests that failed in a control run, by `controlRunFailures`, or are flaky for what they did alone, those
    /// that fail most often first.
    static func flakyTests(
        ranked: [Test],
        controlRunFailures flaky: [FailedTestLine.TestIdentity: Int],
        evidence: [FailedTestLine.TestIdentity: Evidence]
    ) -> [FlakyTest] {
        Set(flaky.keys).union(ranked.filter(\.isFlaky).map(\.identity))
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
            }
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
