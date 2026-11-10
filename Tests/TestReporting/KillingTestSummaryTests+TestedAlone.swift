@testable import muterCore
import XCTest

extension KillingTestSummaryTests {
    /// Thresholds that make a test suspect once it fails for mutants in half of at least two files.
    private var lowThresholds: SuspectTestThresholds { SuspectTestThresholds(filePercent: 50, minimumFiles: 2) }
    /// A test that failed again when run alone.
    private var again: String { MutantResult.Rerun.TestAlone.failedAgain }
    /// A test that passed when run alone.
    private var passedAlone: String { MutantResult.Rerun.TestAlone.passed }

    /// A mutant in `file` that `tests` failed for first, tested again alone, each test doing as `results` says, and
    /// that came to `outcome` with `then` failing.
    private func testedAlone(
        in file: String,
        first tests: [FailedTestLine.FailedTest],
        results: [String?],
        outcome: TestSuiteOutcome = .failed,
        then: [FailedTestLine.FailedTest]? = nil
    ) -> MutationTestOutcome.Mutation {
        var mutation = mutant(
            outcome,
            in: file,
            killingTests: outcome == .passed
                ? nil : .init(tests: then ?? tests, count: (then ?? tests).count, isComplete: true)
        )
        mutation.rerun = .init(
            because: MutantResult.Rerun.onlySuspectTestsFailed,
            workers: 1,
            alone: zip(tests, results).map { test, result in
                let identity = FailedTestLine.TestIdentity(test)
                return .init(name: identity.name, file: identity.file, result: result)
            }
        )
        return mutation
    }

    func test_aBroadTestThatFailsAgainEveryTime_isCleared() throws {
        let broad = failedTest("broad()")
        let mutations = (0 ..< 3).map { testedAlone(in: "F\($0).swift", first: [broad], results: [again]) }

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations, thresholds: lowThresholds))

        let test = try XCTUnwrap(summary.tests.first)
        XCTAssertFalse(test.suspect)
        XCTAssertTrue(test.clearedAlone)
        XCTAssertEqual(test.suspectCell, "cleared")
        XCTAssertEqual(summary.suspectOnlyKills, 0)
        XCTAssertNil(summary.warning(mutationScore: 100))
        XCTAssertEqual(summary.flakyTests, [])
        XCTAssertEqual(summary.suspectsWhateverTheyDidAlone, [test.identity])
        XCTAssertTrue(
            summary.testedAloneSentences.joined().contains("isn't suspect, however far it reaches: broad() in 3.")
        )
    }

    // Two chance failures of a test that fails a third of the time would otherwise clear it.
    func test_tooFewFailuresAlone_dontClearATest() throws {
        let broad = failedTest("broad()")
        let mutations = (0 ..< 2).map { testedAlone(in: "F\($0).swift", first: [broad], results: [again]) }

        let test = try XCTUnwrap(KillingTestSummary(of: mutations, thresholds: lowThresholds)?.tests.first)

        XCTAssertTrue(test.suspect)
        XCTAssertFalse(test.clearedAlone)
    }

    func test_aTestThatMostlyDoesntFailAgain_isFlaky_withItsKillsFlipped() throws {
        let flaky = failedTest("flaky()")
        let mutations = [
            testedAlone(in: "A.swift", first: [flaky], results: [again]),
            testedAlone(in: "B.swift", first: [flaky], results: [passedAlone], outcome: .passed),
            testedAlone(in: "C.swift", first: [flaky], results: [passedAlone], outcome: .passed),
        ]

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations, thresholds: lowThresholds))

        let test = try XCTUnwrap(summary.tests.first)
        XCTAssertTrue(test.suspect)
        XCTAssertEqual(test.suspectCell, "flaky")
        XCTAssertEqual(test.files, 3)
        XCTAssertEqual(summary.flakyTests, [
            .init(name: "flaky()", file: "SumTests.swift", controlRuns: 0, failedAgainAlone: 1, notReproducedAlone: 2),
        ])
        XCTAssertEqual(summary.killsTestedAlone, 3)
        XCTAssertEqual(summary.killsThatSurvivedAlone, 2)
        // The one left only it failed for, on its own word, still doesn't count in the score without it.
        XCTAssertEqual(summary.suspectOnlyKills, 1)
        XCTAssertEqual(summary.suspectOnlyKillsNotTestedAlone, 0)
        XCTAssertEqual(
            summary.warning(mutationScore: 33),
            "1 test may fail whatever the mutant: it didn't fail again often enough when tested alone "
                + "(flaky() failed again in 1 of 3). "
                + "Without its failures, the mutation score would be 0%, not 33%."
        )
        XCTAssertTrue(summary.testedAloneSentences.contains {
            $0.contains("often enough alone is flaky, so it is suspect: flaky() failed again in 1 of 3")
        })
    }

    // A flip takes a test's kills, but what it did stays on the report, so a falling score has an explanation.
    func test_aTestWhoseEveryKillFlipped_staysOnTheReport() throws {
        let flaky = failedTest("flaky()")
        let summary = try XCTUnwrap(KillingTestSummary(of: [
            testedAlone(in: "A.swift", first: [flaky], results: [passedAlone], outcome: .passed),
        ]))

        XCTAssertEqual(summary.killedMutants, 0)
        XCTAssertEqual(summary.tests.map(\.name), ["flaky()"])
        XCTAssertEqual(summary.suspects.map(\.name), ["flaky()"])
        XCTAssertEqual(summary.killsThatSurvivedAlone, 1)
        XCTAssertNotNil(summary.warning(mutationScore: 0))
        XCTAssertEqual(summary.filesWithKillsLeft, 0)
        XCTAssertTrue(summary.suspectSentences(mutationScore: 0).contains {
            $0.hasPrefix("No mutant counts as killed only by suspect tests any more.")
        })
    }

    // A later SwiftMutator may add a result. This one can't read it, so it says nothing, either way.
    func test_aResultThisVersionDoesntKnow_saysNothing() throws {
        let test = try XCTUnwrap(KillingTestSummary(of: [
            testedAlone(in: "A.swift", first: [failedTest("a()")], results: ["somethingNew"]),
        ])?.tests.first)

        XCTAssertEqual(test.failedAgainAlone, 0)
        XCTAssertEqual(test.notReproducedAlone, 0)
    }

    func test_onlyRecordedFailureOf_goesByTheRerunsList_whileItStillFails() throws {
        let focused = failedTest("focused()")
        let other = failedTest("other()")
        let summary = try XCTUnwrap(KillingTestSummary(of: [
            testedAlone(in: "A.swift", first: [focused], results: [again], then: [focused, other]),
            testedAlone(in: "B.swift", first: [focused], results: [again]),
            testedAlone(in: "C.swift", first: [focused], results: [passedAlone], outcome: .passed),
        ]))

        XCTAssertEqual(summary.tests.first?.mutants, 3)
        XCTAssertEqual(summary.tests.first?.onlyRecordedFailureOf, 2)
    }

    // One pass in many reproductions is chance, or a test that sometimes misses, so what it reaches decides.
    func test_oneMissAmongEnoughFailuresAlone_leavesTheRuleToDecide() throws {
        let broad = failedTest("broad()")
        let mutations = (0 ..< 4).map { testedAlone(in: "F\($0).swift", first: [broad], results: [again]) }
            + [testedAlone(in: "G.swift", first: [broad], results: [passedAlone], outcome: .passed)]

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations, thresholds: lowThresholds))
        XCTAssertEqual(summary.tests.first?.suspect, true)
        XCTAssertEqual(summary.tests.first?.isFlaky, false)
        XCTAssertEqual(summary.tests.first?.suspectCell, "yes")

        let farFromEnough = try XCTUnwrap(KillingTestSummary(
            of: mutations, thresholds: SuspectTestThresholds(filePercent: 100, minimumFiles: 100)
        ))
        XCTAssertEqual(farFromEnough.tests.first?.suspect, false)
    }

    func test_nothingClearsAFailedControlRun() throws {
        let broad = failedTest("broad()")
        let mutations = (0 ..< 3).map { testedAlone(in: "F\($0).swift", first: [broad], results: [again]) }
        let control = MutationTestOutcome.ControlRun(
            outcome: .failed,
            failedTests: .init(tests: [broad], count: 1, isComplete: true)
        )

        let test = try XCTUnwrap(
            KillingTestSummary(of: mutations, controlRuns: [control], thresholds: lowThresholds)?.tests.first
        )

        XCTAssertTrue(test.suspect)
        XCTAssertFalse(test.clearedAlone)
        XCTAssertEqual(test.suspectCell, "flaky")
    }

    // A run may reach further with no first failure to stop it. What it shows mustn't change who is suspect.
    func test_reach_isMeasuredOnFirstRuns_notOnARerunsLongerList() throws {
        let focused = failedTest("focused()")
        let other = failedTest("other()")
        let mutations = (0 ..< 3).map {
            testedAlone(in: "F\($0).swift", first: [focused], results: [again], then: [focused, other])
        }

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations, thresholds: lowThresholds))

        XCTAssertEqual(summary.tests.map(\.name), ["focused()"])
        XCTAssertEqual(summary.filesWithKills, 3)
    }

    // Reuse keeps which tests failed first, for their reach, but not what they did on code that may have changed.
    func test_aRerunReusedFromAnotherFile_saysNothingOfWhatATestDidAlone() throws {
        let flaky = failedTest("flaky()")
        var reused = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .passed,
            point: .make(filePath: "/project/Sources/A.swift"),
            reusedFrom: .init(resultsFile: "r", session: 1, despiteChanges: false)
        )
        reused.rerun = testedAlone(in: "A.swift", first: [flaky], results: [passedAlone], outcome: .passed)
            .rerun?.withoutEvidence

        let summary = try XCTUnwrap(KillingTestSummary(of: [reused]))

        XCTAssertEqual(summary.tests.first?.notReproducedAlone, 0)
        XCTAssertEqual(summary.tests.first?.suspect, false)
        XCTAssertEqual(summary.flakyTests, [])
        XCTAssertEqual(summary.killsTestedAlone, 0)
    }

    func test_killsNotTestedAlone_areCounted_andSaid() throws {
        let flaky = failedTest("flaky()")
        let summary = try XCTUnwrap(KillingTestSummary(of: [
            testedAlone(in: "A.swift", first: [flaky], results: [passedAlone], outcome: .passed),
            kill(in: "B.swift", naming: [flaky]),
            kill(in: "C.swift", naming: [flaky]),
        ]))

        XCTAssertEqual(summary.suspectOnlyKills, 2)
        XCTAssertEqual(summary.suspectOnlyKillsNotTestedAlone, 2)
        XCTAssertEqual(
            summary.testedAloneSentences.last?.hasPrefix("2 mutants only suspect tests failed for"),
            true
        )
    }

    func test_testedAloneSentences_areNone_withNoSuchRun() throws {
        XCTAssertEqual(
            try XCTUnwrap(KillingTestSummary(of: [kill(in: "A.swift", naming: [failedTest("a()")])]))
                .testedAloneSentences,
            []
        )
    }
}
