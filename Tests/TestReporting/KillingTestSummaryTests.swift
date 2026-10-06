@testable import muterCore
import XCTest

final class KillingTestSummaryTests: XCTestCase {
    func test_isNil_withoutRecordedKillingTests() {
        let sum = failedTest("sum()")

        XCTAssertNil(KillingTestSummary(of: []))
        XCTAssertNil(KillingTestSummary(of: [
            kill(in: "Sum.swift", naming: nil),
            mutant(.runtimeError, in: "Crash.swift", killingTests: .init(tests: [sum], count: 1, isComplete: true)),
            mutant(.timeout, in: "Slow.swift", killingTests: .init(tests: [], count: 0, isComplete: false)),
            mutant(.passed, in: "Survivor.swift", killingTests: nil),
            mutant(.buildError, in: "Broken.swift", killingTests: nil),
        ]))
    }

    func test_countsEachTestOncePerMutant_withItsFiles_andOnlyRecordedFailures() throws {
        let sum = failedTest("sum()", in: "SumTests.swift")
        let sumAtAnotherLine = failedTest("sum()", in: "SumTests.swift", line: 9)
        let total = failedTest("total()", in: "TotalTests.swift")

        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", line: 3, naming: [sum]),
            kill(in: "Sum.swift", line: 7, naming: [sum, total]),
            // The same test, recorded at two lines of its file: one test, once for this mutant, and its only failure.
            kill(in: "Total.swift", line: 2, naming: [sum, sumAtAnotherLine], count: 1),
            // More failed than the list holds, so total() isn't the only one that did.
            kill(in: "Total.swift", line: 5, naming: [total], count: 3, isComplete: false),
        ]))

        XCTAssertEqual(summary.tests, [
            .init(
                name: "sum()",
                file: "SumTests.swift",
                mutants: 3,
                files: 2,
                onlyRecordedFailureOf: 2,
                suspect: false
            ),
            .init(
                name: "total()",
                file: "TotalTests.swift",
                mutants: 2,
                files: 2,
                onlyRecordedFailureOf: 0,
                suspect: false
            ),
        ])
        XCTAssertEqual(summary.killedMutants, 4)
        XCTAssertEqual(summary.filesWithKills, 2)
        XCTAssertEqual(summary.distinctTests, 2)
    }

    func test_sameNameInTwoFiles_isTwoTests_twoLocationsInOneFile_isOne() throws {
        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "A.swift", naming: [failedTest("check()", in: "ATests.swift", line: 3)]),
            kill(in: "B.swift", naming: [failedTest("check()", in: "ATests.swift", line: 8)]),
            kill(in: "C.swift", naming: [failedTest("check()", in: "BTests.swift", line: 3)]),
            kill(in: "D.swift", naming: [failedTest("-[Tests.CheckTests testCheck]", in: nil)]),
        ]))

        XCTAssertEqual(summary.tests.map(\.name), ["check()", "-[Tests.CheckTests testCheck]", "check()"])
        XCTAssertEqual(summary.tests.map(\.file), ["ATests.swift", nil, "BTests.swift"])
        XCTAssertEqual(summary.tests.map(\.mutants), [2, 1, 1])
        XCTAssertEqual(summary.tests.map(\.files), [2, 1, 1])
        XCTAssertEqual(summary.distinctTests, 3)
    }

    func test_crashesTimeoutsAndSurvivors_areNotCounted() throws {
        let sum = failedTest("sum()")
        let crash = failedTest("crash()", in: "CrashTests.swift")
        let slow = failedTest("slow()", in: "SlowTests.swift")

        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", naming: [sum]),
            mutant(.runtimeError, in: "Crash.swift", killingTests: .init(tests: [crash], count: 1, isComplete: true)),
            mutant(.timeout, in: "Slow.swift", killingTests: .init(tests: [slow], count: 1, isComplete: false)),
            mutant(.passed, in: "Survivor.swift", killingTests: nil),
            mutant(.buildError, in: "Broken.swift", killingTests: nil),
        ]))

        XCTAssertEqual(summary.tests, [
            .init(
                name: "sum()",
                file: "SumTests.swift",
                mutants: 1,
                files: 1,
                onlyRecordedFailureOf: 1,
                suspect: false
            ),
        ])
        XCTAssertEqual(summary.killedMutants, 1)
        XCTAssertEqual(summary.killedMutantsNotRecorded, 0)
        XCTAssertEqual(summary.incompleteLists, 0)
        XCTAssertEqual(summary.filesWithKills, 1)
        XCTAssertEqual(summary.distinctTests, 1)
    }

    func test_emptyAndMissingLists_areCountedApart_andAddNoFiles() throws {
        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", naming: [failedTest("sum()")]),
            kill(in: "Empty.swift", line: 1, naming: []),
            kill(in: "Empty.swift", line: 2, naming: []),
            kill(in: "Unrecorded.swift", naming: nil),
        ]))

        XCTAssertEqual(summary.killedMutants, 3)
        XCTAssertEqual(summary.killedMutantsNamingNoTest, 2)
        XCTAssertEqual(summary.killedMutantsNotRecorded, 1)
        XCTAssertEqual(summary.filesWithKills, 1)
        XCTAssertEqual(summary.tests.map(\.mutants), [1])

        let namingNone = try XCTUnwrap(KillingTestSummary(of: [kill(in: "Empty.swift", naming: [])]))
        XCTAssertEqual(namingNone.killedMutants, 1)
        XCTAssertEqual(namingNone.killedMutantsNamingNoTest, 1)
        XCTAssertEqual(namingNone.filesWithKills, 0)
        XCTAssertEqual(namingNone.tests, [])
        XCTAssertEqual(namingNone.distinctTests, 0)
    }

    func test_ordersByMutantsThenNameThenFile_keepsTen_plusEverySuspect() throws {
        let ordered = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "One.swift", naming: [failedTest("b()", in: "BTests.swift")]),
            kill(in: "Two.swift", naming: [failedTest("b()", in: "BTests.swift")]),
            kill(in: "Three.swift", naming: [failedTest("a()", in: "BTests.swift")]),
            kill(in: "Four.swift", naming: [failedTest("a()", in: "ATests.swift")]),
            // Swift Testing's issue with no location: no file, which comes first.
            kill(in: "Five.swift", naming: [failedTest("a()", in: nil)]),
        ]))
        XCTAssertEqual(ordered.tests.map(\.name), ["b()", "a()", "a()", "a()"])
        XCTAssertEqual(ordered.tests.map(\.file), ["BTests.swift", nil, "ATests.swift", "BTests.swift"])

        // 11 focused tests that each failed for 12 mutants in one file, then one that failed for a mutant in each of
        // 10 other files: 10 of the 21 files with a kill, so suspect, though only 12th by mutants.
        let focused = (0 ... 10).flatMap { index in
            let test = failedTest(String(format: "focused%02d()", index))
            return (1 ... 12).map { line in kill(in: "Focused\(index).swift", line: line, naming: [test]) }
        }
        let flaky = (0 ..< 10).map { index in
            kill(in: "Flaky\(index).swift", naming: [failedTest("flaky()", in: "FlakyTests.swift")])
        }

        let summary = try XCTUnwrap(KillingTestSummary(of: flaky + focused))

        XCTAssertEqual(KillingTestSummary.shownTests, 10)
        XCTAssertEqual(summary.filesWithKills, 21)
        XCTAssertEqual(summary.distinctTests, 12)
        XCTAssertEqual(
            summary.tests.map(\.name),
            (0 ..< 10).map { String(format: "focused%02d()", $0) } + ["flaky()"]
        )
        XCTAssertEqual(summary.tests.map(\.suspect), Array(repeating: false, count: 10) + [true])
    }

    func test_countsIncompleteLists() throws {
        let sum = failedTest("sum()")

        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", line: 1, naming: [sum]),
            // Stopped at its first failed test.
            kill(in: "Sum.swift", line: 2, naming: [sum], count: 1, isComplete: false),
            // More failed than a list holds.
            kill(in: "Sum.swift", line: 3, naming: [sum], count: FailedTestLine.killedByLimit + 5, isComplete: false),
            // Names none, so isn't counted.
            kill(in: "Sum.swift", line: 4, naming: [], isComplete: false),
            mutant(.runtimeError, in: "Crash.swift", killingTests: .init(tests: [sum], count: 1, isComplete: false)),
        ]))

        XCTAssertEqual(summary.incompleteLists, 2)
        XCTAssertEqual(summary.killedMutants, 4)
    }

    func test_countSentences_sayOneInTheSingular() throws {
        let sum = failedTest("sum()")

        let alone = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", line: 1, naming: [sum], count: 1, isComplete: false),
            kill(in: "Sum.swift", line: 2, naming: []),
            kill(in: "Sum.swift", line: 3, naming: nil),
        ]))
        XCTAssertEqual(alone.countSentences, [
            "1 killed mutant names the tests that failed for it, in 1 file.",
            "It stopped at its first failed test or its time limit, or names more than 20 tests, so it may not name "
                + "every test that failed.",
            "1 more killed mutant names no test, as no line of its log shows one failing.",
            "The tests that failed for 1 more killed mutant weren't recorded.",
        ])

        let oneOfTwo = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", naming: [sum], count: 1, isComplete: false),
            kill(in: "Total.swift", naming: [sum]),
        ]))
        XCTAssertEqual(oneOfTwo.countSentences, [
            "2 killed mutants name the tests that failed for them, in 2 files.",
            "1 of them stopped at its first failed test or its time limit, or names more than 20 tests, so it may not "
                + "name every test that failed.",
        ])
    }

    func test_countSentences_sayMoreThanOneInThePlural() throws {
        let sum = failedTest("sum()")

        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", line: 1, naming: [sum], count: 1, isComplete: false),
            kill(in: "Sum.swift", line: 2, naming: [sum], count: 1, isComplete: false),
            kill(in: "Total.swift", naming: [sum]),
            kill(in: "Empty.swift", line: 1, naming: []),
            kill(in: "Empty.swift", line: 2, naming: []),
            kill(in: "Unrecorded.swift", line: 1, naming: nil),
            kill(in: "Unrecorded.swift", line: 2, naming: nil),
        ]))

        XCTAssertEqual(summary.countSentences, [
            "3 killed mutants name the tests that failed for them, in 2 files.",
            "2 of them stopped at their first failed test or their time limit, or name more than 20 tests, so they "
                + "may not name every test that failed.",
            "2 more killed mutants name no test, as no line of their logs shows one failing.",
            "The tests that failed for 2 more killed mutants weren't recorded.",
        ])
    }

    func test_countSentences_whenNoKillNamesATest_sayOnlyThat() throws {
        let summary = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Empty.swift", line: 1, naming: []),
            kill(in: "Empty.swift", line: 2, naming: []),
            kill(in: "Unrecorded.swift", naming: nil),
        ]))

        XCTAssertEqual(summary.countSentences, [
            "2 killed mutants name no test, as no line of their logs shows one failing.",
            "The tests that failed for 1 more killed mutant weren't recorded.",
        ])
    }

    func test_suspectRule_atItsBoundaries() throws {
        XCTAssertEqual(KillingTestSummary.suspectFilePercent, 15)
        XCTAssertEqual(KillingTestSummary.suspectMinimumFiles, 10)

        XCTAssertTrue(KillingTestSummary.isSuspect(files: 10, filesWithKills: 66))
        XCTAssertFalse(KillingTestSummary.isSuspect(files: 10, filesWithKills: 67))
        XCTAssertTrue(KillingTestSummary.isSuspect(files: 15, filesWithKills: 100))
        XCTAssertFalse(KillingTestSummary.isSuspect(files: 14, filesWithKills: 100))
        for filesWithKills in 9 ... 60 {
            XCTAssertFalse(KillingTestSummary.isSuspect(files: 9, filesWithKills: filesWithKills), "\(filesWithKills)")
        }

        // A test that failed for a mutant in every file is suspect only once 10 files have one.
        let timing = failedTest("timing()", in: "TimingTests.swift")
        let killsInEveryFile = { (files: Int) in (0 ..< files).map { self.kill(in: "F\($0).swift", naming: [timing]) } }
        let nineFiles = try XCTUnwrap(KillingTestSummary(of: killsInEveryFile(9)))
        XCTAssertEqual(nineFiles.filesWithKills, 9)
        XCTAssertFalse(nineFiles.suspectsChecked)
        XCTAssertEqual(nineFiles.tests.map(\.suspect), [false])

        let tenFiles = try XCTUnwrap(KillingTestSummary(of: killsInEveryFile(10)))
        XCTAssertTrue(tenFiles.suspectsChecked)
        XCTAssertEqual(tenFiles.tests.map(\.suspect), [true])
    }

    /// Shaped as SwiftProjectLint's run of 2026-10-02 at 2:20 AM, under load: of 132 files with a kill, the timing
    /// test failed for mutants in 128, the arrival-order test in 60, and the widest good test in 11.
    func test_aBeforeRunShapedOutcome_flagsOnlyTheTwoLoadFlakyTests() throws {
        let timing = failedTest("testAnalyzeProjectPerformance()", in: "ProjectLinterTests.swift")
        let arrivalOrder = failedTest(
            "everyFormatRendersTheSameBytesForAnyArrivalOrder()",
            in: "ReportOrderDeterminismLawsTests.swift"
        )
        let registry = failedTest(#""every selectable rule is registered""#, in: "RuleRegistrationTests.swift")
        let mutations = (0 ..< 132).map { index in
            kill(
                in: "Visitor\(index).swift",
                naming: [failedTest("focused\(index)()", in: "Visitor\(index)Tests.swift")]
                    + (index < 128 ? [timing] : [])
                    + (70 ..< 130 ~= index ? [arrivalOrder] : [])
                    + (index < 11 ? [registry] : [])
            )
        }

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations))

        XCTAssertEqual(summary.filesWithKills, 132)
        XCTAssertTrue(summary.suspectsChecked)
        XCTAssertEqual(summary.tests.prefix(3).map(\.files), [128, 60, 11])
        XCTAssertEqual(summary.tests.filter(\.suspect).map(\.name), [timing.name, arrivalOrder.name])
    }

    /// Shaped as SwiftProjectLint's run of 2026-10-02 at 1:16 PM: of 276 files with a kill, the widest test failed for
    /// mutants in 18.
    func test_anAfterRunShapedOutcome_flagsNothing() throws {
        let registry = failedTest(#""the registry accounts for every rule""#, in: "RuleRegistrationTests.swift")
        let layers = failedTest("reportsLayersThatMayDependOnEachOtherOnce()", in: "LayerTests.swift")
        let mutations = (0 ..< 276).map { index in
            kill(
                in: "Visitor\(index).swift",
                naming: [failedTest("focused\(index)()", in: "Visitor\(index)Tests.swift")]
                    + (index < 18 ? [registry] : [])
                    + (100 ..< 112 ~= index ? [layers] : [])
            )
        }

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations))

        XCTAssertEqual(summary.filesWithKills, 276)
        XCTAssertTrue(summary.suspectsChecked)
        XCTAssertEqual(summary.tests.prefix(2).map(\.files), [18, 12])
        XCTAssertEqual(summary.tests.filter(\.suspect), [])
        XCTAssertEqual(summary.suspectOnlyKills, 0)
        XCTAssertNil(summary.mutationScoreWithoutSuspectOnlyKills)
        XCTAssertNil(summary.warning(mutationScore: 100))
    }

    func test_suspectOnlyKills_needANonEmptyListOfSuspectsOnly() {
        let timing = failedTest("timing()", in: "TimingTests.swift")
        let order = failedTest("order()", in: "OrderTests.swift")
        let focused = failedTest("focused()", in: "FocusedTests.swift")
        let suspects: Set<FailedTestLine.TestIdentity> = [.init(timing), .init(order)]
        let isSuspectOnly = { (mutation: MutationTestOutcome.Mutation) in
            KillingTestSummary.isSuspectOnlyKill(mutation, suspects: suspects)
        }

        XCTAssertTrue(isSuspectOnly(kill(in: "A.swift", naming: [timing])))
        XCTAssertTrue(isSuspectOnly(kill(in: "A.swift", naming: [timing, order])))
        // The same test, its issue recorded at another line of its file.
        let timingAtAnotherLine = failedTest("timing()", in: "TimingTests.swift", line: 9)
        XCTAssertTrue(isSuspectOnly(kill(in: "A.swift", naming: [timingAtAnotherLine])))
        // A list that stopped short is still only suspects, as far as it goes.
        XCTAssertTrue(isSuspectOnly(kill(in: "A.swift", naming: [timing], count: 1, isComplete: false)))

        XCTAssertFalse(isSuspectOnly(kill(in: "A.swift", naming: [timing, focused])))
        XCTAssertFalse(isSuspectOnly(kill(in: "A.swift", naming: [focused])))
        XCTAssertFalse(isSuspectOnly(kill(in: "A.swift", naming: [])), "a list naming none names no suspect")
        XCTAssertFalse(isSuspectOnly(kill(in: "A.swift", naming: nil)))
        XCTAssertFalse(isSuspectOnly(kill(in: "A.swift", naming: [failedTest("timing()", in: "OtherTests.swift")])))
        XCTAssertFalse(isSuspectOnly(
            mutant(.runtimeError, in: "A.swift", killingTests: .init(tests: [timing], count: 1, isComplete: true))
        ))
        XCTAssertFalse(KillingTestSummary.isSuspectOnlyKill(kill(in: "A.swift", naming: [timing]), suspects: []))

        // In a summary: timing() and order() failed for a mutant in each of 10 files, alone in 3 of them.
        let summary = KillingTestSummary(of: (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: [timing, order] + (index < 3 ? [] : [focused]))
        })
        XCTAssertEqual(summary?.tests.filter(\.suspect).map(\.name), ["order()", "timing()"])
        XCTAssertEqual(summary?.suspectOnlyKills, 3)
    }

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
        let marked = report.fileReports.flatMap(\.appliedOperators).filter { $0.killedOnlyBySuspectTests != nil }
        XCTAssertEqual(marked.map(\.killedOnlyBySuspectTests), Array(repeating: true, count: 4))
        XCTAssertEqual(Set(marked.map(\.mutationPoint.fileName)), ["F0.swift", "F1.swift", "F2.swift", "F3.swift"])

        // A suspect that never failed alone leaves no other score.
        let withFocusedTests = try XCTUnwrap(KillingTestSummary(of: (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: [timing, failedTest("focused\(index)()")])
        }))
        XCTAssertEqual(withFocusedTests.tests.filter(\.suspect).map(\.name), ["timing()"])
        XCTAssertEqual(withFocusedTests.suspectOnlyKills, 0)
        XCTAssertNil(withFocusedTests.mutationScoreWithoutSuspectOnlyKills)
        XCTAssertNil(MuterTestReport(from: .make(mutations: [kill(in: "F0.swift", naming: [timing])])).fileReports
            .first?.appliedOperators.first?.killedOnlyBySuspectTests)
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
        // Five suspects among 20 files: a() failed for a mutant in each, b() in 18, c() in 16, d() in 14, e() in 12.
        // The first 10 files' kills name only them; the rest also name a focused test.
        let suspectFiles: [(name: String, files: Int)] = [
            ("a()", 20), ("b()", 18), ("c()", 16), ("d()", 14), ("e()", 12),
        ]
        let mutations = { (firstIsComplete: Bool) in
            (0 ..< 20).map { index in
                let suspects = suspectFiles
                    .filter { index < $0.files }
                    .map { self.failedTest($0.name, in: "SuspectTests.swift") }
                let focused = index < 10 ? [] : [self.failedTest("focused\(index)()", in: "F\(index)Tests.swift")]
                return self.kill(
                    in: "F\(index).swift",
                    naming: suspects + focused,
                    count: suspects.count + focused.count + (index == 0 && !firstIsComplete ? 1 : 0),
                    isComplete: index > 0 || firstIsComplete
                )
            }
        }

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
}

private extension KillingTestSummaryTests {
    /// A Swift Testing test whose issue was recorded in `file`, or, with no file, one without a location.
    func failedTest(_ name: String, in file: String? = "SumTests.swift", line: Int = 3) -> FailedTestLine.FailedTest {
        .init(name: name, location: file.map { "\($0):\(line):5" })
    }

    /// A mutant in `file` a failed test killed, with `tests` recorded failing: `count` of them, all by default.
    func kill(
        in file: String,
        line: Int = 1,
        naming tests: [FailedTestLine.FailedTest]?,
        count: Int? = nil,
        isComplete: Bool = true
    ) -> MutationTestOutcome.Mutation {
        mutant(
            .failed,
            in: file,
            line: line,
            killingTests: tests.map { .init(tests: $0, count: count ?? $0.count, isComplete: isComplete) }
        )
    }

    func mutant(
        _ outcome: TestSuiteOutcome,
        in file: String,
        line: Int = 1,
        killingTests: MutationTestOutcome.KillingTests?
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(filePath: "/project/Sources/\(file)", position: .init(integerLiteral: line)),
            killingTests: killingTests
        )
    }
}
