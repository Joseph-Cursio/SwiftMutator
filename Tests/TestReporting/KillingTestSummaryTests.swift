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
