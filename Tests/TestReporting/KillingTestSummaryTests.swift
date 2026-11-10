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
            kill(in: "Sum.swift", naming: [sum], line: 3),
            kill(in: "Sum.swift", naming: [sum, total], line: 7),
            // The same test, recorded at two lines of its file: one test, once for this mutant, and its only failure.
            kill(in: "Total.swift", naming: [sum, sumAtAnotherLine], line: 2, count: 1),
            // More failed than the list holds, so total() isn't the only one that did.
            kill(in: "Total.swift", naming: [total], line: 5, count: 3, isComplete: false),
        ]))

        XCTAssertEqual(summary.tests, [
            .init(
                name: "sum()",
                file: "SumTests.swift",
                mutants: 3,
                files: 2,
                onlyRecordedFailureOf: 2,
                failedControlRuns: 0,
                suspect: false
            ),
            .init(
                name: "total()",
                file: "TotalTests.swift",
                mutants: 2,
                files: 2,
                onlyRecordedFailureOf: 0,
                failedControlRuns: 0,
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
                failedControlRuns: 0,
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
            kill(in: "Empty.swift", naming: [], line: 1),
            kill(in: "Empty.swift", naming: [], line: 2),
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
            return (1 ... 12).map { line in kill(in: "Focused\(index).swift", naming: [test], line: line) }
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
            kill(in: "Sum.swift", naming: [sum], line: 1),
            // Stopped at its first failed test.
            kill(in: "Sum.swift", naming: [sum], line: 2, count: 1, isComplete: false),
            // More failed than a list holds.
            kill(in: "Sum.swift", naming: [sum], line: 3, count: FailedTestLine.killedByLimit + 5, isComplete: false),
            // Names none, so isn't counted.
            kill(in: "Sum.swift", naming: [], line: 4, isComplete: false),
            mutant(.runtimeError, in: "Crash.swift", killingTests: .init(tests: [sum], count: 1, isComplete: false)),
        ]))

        XCTAssertEqual(summary.incompleteLists, 2)
        XCTAssertEqual(summary.killedMutants, 4)
    }

    func test_countSentences_sayOneInTheSingular() throws {
        let sum = failedTest("sum()")

        let alone = try XCTUnwrap(KillingTestSummary(of: [
            kill(in: "Sum.swift", naming: [sum], line: 1, count: 1, isComplete: false),
            kill(in: "Sum.swift", naming: [], line: 2),
            kill(in: "Sum.swift", naming: nil, line: 3),
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
            kill(in: "Sum.swift", naming: [sum], line: 1, count: 1, isComplete: false),
            kill(in: "Sum.swift", naming: [sum], line: 2, count: 1, isComplete: false),
            kill(in: "Total.swift", naming: [sum]),
            kill(in: "Empty.swift", naming: [], line: 1),
            kill(in: "Empty.swift", naming: [], line: 2),
            kill(in: "Unrecorded.swift", naming: nil, line: 1),
            kill(in: "Unrecorded.swift", naming: nil, line: 2),
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
            kill(in: "Empty.swift", naming: [], line: 1),
            kill(in: "Empty.swift", naming: [], line: 2),
            kill(in: "Unrecorded.swift", naming: nil),
        ]))

        XCTAssertEqual(summary.countSentences, [
            "2 killed mutants name no test, as no line of their logs shows one failing.",
            "The tests that failed for 1 more killed mutant weren't recorded.",
        ])
    }
}
