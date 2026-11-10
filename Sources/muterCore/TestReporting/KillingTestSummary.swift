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

        /// Which test it is, as each mutant's list tells them apart.
        var identity: FailedTestLine.TestIdentity {
            .init(name: name, file: file)
        }

        /// Whether it fails whatever the mutant, as a control run or what it did alone shows.
        var isFlaky: Bool {
            failedControlRuns > 0
                || KillingTestSummary.isFlakyAlone(failedAgain: failedAgainAlone, notReproduced: notReproducedAlone)
        }

        /// Its Suspect cell in the reports' tables: "flaky" when a control run or what it did alone shows it is, "yes"
        /// when it is suspect for the files it failed for mutants in, "cleared" when it would be but failed again every
        /// time alone, "-" otherwise.
        var suspectCell: String {
            isFlaky ? "flaky" : suspect ? "yes" : clearedAlone ? "cleared" : "-"
        }
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

        /// Which test it is, as each mutant's list tells them apart.
        var identity: FailedTestLine.TestIdentity {
            .init(name: name, file: file)
        }
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
