@testable import muterCore
import XCTest

extension KillingTestSummaryTests {
    func test_scoreWithoutSuspects_countsThemAsSurvivors_andKeepsCrashKills() throws {
        let timing = failedTest("timing()", in: "TimingTests.swift")
        // timing() failed for a mutant in each of 10 files: alone for 4, with a focused test for 6. A crash only
        // timing() failed for stays a kill, as do a kill that names no test and one with none recorded.
        let mutations = (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: [timing] + (index < 4 ? [] : [failedTest("focused\(index)()")]))
        } + [
            mutant(.runtimeError, in: "Crash.swift", killingTests: .init(tests: [timing], count: 1, isComplete: true)),
            kill(in: "Empty.swift", naming: []),
            kill(in: "Unrecorded.swift", naming: nil),
            mutant(.passed, in: "Survivor.swift", killingTests: nil),
            mutant(.buildError, in: "Broken.swift", killingTests: nil),
        ]

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations))

        XCTAssertEqual(summary.tests.filter(\.suspect).map(\.name), ["timing()"])
        XCTAssertEqual(summary.suspectOnlyKills, 4)
        XCTAssertEqual(summary.suspectOnlyKillsWithIncompleteLists, 0)
        // 13 of the 14 mutants that built were killed: 92%. Without the 4, 9 of 14: 64%, truncated as the headline is.
        XCTAssertEqual(mutationScore(from: mutations.map(\.testSuiteOutcome)), 92)
        XCTAssertEqual(summary.mutationScoreWithoutSuspectOnlyKills, 64)

        // The report's headline and killed count don't change; each suspect-only kill is marked, and nothing else.
        let report = MuterTestReport(from: .make(mutations: mutations))
        XCTAssertEqual(report.globalMutationScore, 92)
        XCTAssertEqual(report.numberOfKilledMutants, 13)
        let marked = report.fileReports.flatMap(\.appliedOperators).filter(\.killedOnlyBySuspectTests)
        XCTAssertEqual(marked.map(\.killedOnlyBySuspectTests), Array(repeating: true, count: 4))
        XCTAssertEqual(Set(marked.map(\.mutationPoint.fileName)), ["F0.swift", "F1.swift", "F2.swift", "F3.swift"])

        // A suspect that never failed alone leaves no other score.
        let withFocusedTests = try XCTUnwrap(KillingTestSummary(of: (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: [timing, failedTest("focused\(index)()")])
        }))
        XCTAssertEqual(withFocusedTests.tests.filter(\.suspect).map(\.name), ["timing()"])
        XCTAssertEqual(withFocusedTests.suspectOnlyKills, 0)
        XCTAssertNil(withFocusedTests.mutationScoreWithoutSuspectOnlyKills)
        XCTAssertEqual(
            MuterTestReport(from: .make(mutations: [kill(in: "F0.swift", naming: [timing])])).fileReports
                .first?.appliedOperators.first?.killedOnlyBySuspectTests,
            false
        )
    }

    func test_anIncompleteSuspectOnlyList_makesTheScoreALowerBound() throws {
        let timing = failedTest("timing()", in: "TimingTests.swift")
        let focused = failedTest("focused()", in: "FocusedTests.swift")
        let mutations = { (stoppedListNamesOnlyTiming: Bool) in
            [
                // Stopped at its first failed test: others may have failed too.
                self.kill(
                    in: "F0.swift",
                    naming: stoppedListNamesOnlyTiming ? [timing] : [timing, focused],
                    count: stoppedListNamesOnlyTiming ? 1 : 2,
                    isComplete: false
                ),
            ] + (1 ..< 10).map { index in self.kill(in: "F\(index).swift", naming: [timing]) }
                + [self.mutant(.passed, in: "Survivor.swift", killingTests: nil)]
        }

        let stopped = try XCTUnwrap(KillingTestSummary(of: mutations(true)))
        XCTAssertEqual(stopped.suspectOnlyKills, 10)
        XCTAssertEqual(stopped.suspectOnlyKillsWithIncompleteLists, 1)
        XCTAssertEqual(stopped.mutationScoreWithoutSuspectOnlyKills, 0)
        XCTAssertTrue(stopped.scoreWithoutSuspectsIsALowerBound)
        XCTAssertEqual(stopped.shownScoreWithoutSuspects(mutationScore: 90), "at least 0%")

        // A stopped list that also names a test that isn't suspect stays a kill, and the score is exact.
        let named = try XCTUnwrap(KillingTestSummary(of: mutations(false)))
        XCTAssertEqual(named.suspectOnlyKills, 9)
        XCTAssertEqual(named.suspectOnlyKillsWithIncompleteLists, 0)
        XCTAssertEqual(named.mutationScoreWithoutSuspectOnlyKills, 9)
        XCTAssertFalse(named.scoreWithoutSuspectsIsALowerBound)
        XCTAssertEqual(named.shownScoreWithoutSuspects(mutationScore: 90), "9%")
    }

    func test_warning_namesThreeThenHowManyMore_andSaysAtLeast() throws {
        let mutations = fiveSuspectsInTwentyFiles

        let complete = try XCTUnwrap(KillingTestSummary(of: mutations(true)))
        XCTAssertEqual(complete.warning(mutationScore: 100), """
        5 tests may fail whatever the mutant: they failed for mutants in at least 15% of the 20 files with a killed \
        mutant (a() in 20, b() in 18, c() in 16, and 2 more). Without their failures, the mutation score would be 50%, \
        not 100%.
        """)
        XCTAssertEqual(complete.suspectNames, "a(), b(), c(), and 2 more")
        XCTAssertEqual(
            KillingTestSummary.warning(for: .make(mutations: mutations(true))),
            complete.warning(mutationScore: 100)
        )

        // The first run named a() to e() and stopped, or more failed than it named: the score is a lower bound.
        let stopped = try XCTUnwrap(KillingTestSummary(of: mutations(false)))
        XCTAssertEqual(stopped.suspectOnlyKillsWithIncompleteLists, 1)
        XCTAssertEqual(
            stopped.warning(mutationScore: 100)?.hasSuffix(
                "Without their failures, the mutation score would be at least 50%, not 100%."
            ),
            true
        )

        // One suspect: named whole, in the singular.
        let timing = failedTest("timing()", in: "TimingTests.swift")
        let one = try XCTUnwrap(KillingTestSummary(of: (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: [timing] + (index < 5 ? [] : [failedTest("focused\(index)()")]))
        } + [mutant(.passed, in: "Survivor.swift", killingTests: nil)]))
        XCTAssertEqual(one.suspectNames, "timing()")
        XCTAssertEqual(one.warning(mutationScore: 90), """
        1 test may fail whatever the mutant: it failed for mutants in at least 15% of the 10 files with a killed \
        mutant (timing() in 10). Without its failures, the mutation score would be 45%, not 90%.
        """)

        // Another test failed for every mutant the suspect did: the score is the same without it.
        let alongside = try XCTUnwrap(KillingTestSummary(of: (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: [timing, failedTest("focused\(index)()")])
        }))
        XCTAssertEqual(
            alongside.warning(mutationScore: 100)?.hasSuffix(
                "(timing() in 10). Without its failures, the mutation score would still be 100%."
            ),
            true
        )

        // No suspect, or too few files to look for one: no warning.
        XCTAssertNil(KillingTestSummary(of: (0 ..< 9).map { kill(in: "F\($0).swift", naming: [timing]) })?
            .warning(mutationScore: 100))
        XCTAssertNil(KillingTestSummary.warning(for: .make(mutations: [kill(in: "F.swift", naming: [timing])])))
        XCTAssertNil(KillingTestSummary.warning(for: .make()))
    }

    /// Five suspects among 20 files: a() failed for a mutant in each, b() in 18, c() in 16, d() in 14, e() in 12.
    /// The first 10 files' kills name only them; the rest also name a focused test. Unless `firstIsComplete`, the
    /// first file's kill names fewer tests than failed.
    func fiveSuspectsInTwentyFiles(firstIsComplete: Bool) -> [MutationTestOutcome.Mutation] {
        let suspectFiles: [(name: String, files: Int)] = [
            ("a()", 20), ("b()", 18), ("c()", 16), ("d()", 14), ("e()", 12),
        ]
        return (0 ..< 20).map { index in
            let suspects = suspectFiles
                .filter { index < $0.files }
                .map { failedTest($0.name, in: "SuspectTests.swift") }
            let focused = index < 10 ? [] : [failedTest("focused\(index)()", in: "F\(index)Tests.swift")]
            return kill(
                in: "F\(index).swift",
                naming: suspects + focused,
                count: suspects.count + focused.count + (index == 0 && !firstIsComplete ? 1 : 0),
                isComplete: index > 0 || firstIsComplete
            )
        }
    }
}
