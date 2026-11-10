@testable import muterCore
import XCTest

extension KillingTestSummaryTests {
    func test_suspectRule_atItsBoundaries() throws {
        XCTAssertEqual(SuspectTestThresholds.standard, SuspectTestThresholds(filePercent: 15, minimumFiles: 10))

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

    func test_suspectRule_followsTheThresholdsItIsGiven() throws {
        let thresholds = SuspectTestThresholds(filePercent: 50, minimumFiles: 2)
        XCTAssertTrue(KillingTestSummary.isSuspect(files: 2, filesWithKills: 4, thresholds: thresholds))
        XCTAssertFalse(KillingTestSummary.isSuspect(files: 2, filesWithKills: 5, thresholds: thresholds))
        XCTAssertFalse(KillingTestSummary.isSuspect(files: 1, filesWithKills: 2, thresholds: thresholds))

        let timing = failedTest("timing()", in: "TimingTests.swift")
        let sum = failedTest("sum()", in: "SumTests.swift")
        let mutations = [
            kill(in: "A.swift", naming: [timing]),
            kill(in: "B.swift", naming: [timing]),
            kill(in: "C.swift", naming: [sum]),
            kill(in: "D.swift", naming: [sum]),
            kill(in: "E.swift", naming: [sum]),
        ]

        // Under the standard thresholds, 5 files are too few for any verdict.
        let standard = try XCTUnwrap(KillingTestSummary(of: mutations))
        XCTAssertFalse(standard.suspectsChecked)
        XCTAssertEqual(
            standard.noVerdictSentence,
            "Tests aren't judged by how many files they reach until 10 files have a killed mutant that names a test; "
                + "this report has 5."
        )

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations, thresholds: thresholds))
        XCTAssertTrue(summary.suspectsChecked)
        XCTAssertEqual(summary.suspectFilePercent, 50)
        XCTAssertEqual(summary.suspectMinimumFiles, 2)
        // sum() in 3 of 5 files, timing() in 2: only sum() reaches 50%.
        XCTAssertEqual(summary.tests.map(\.name), ["sum()", "timing()"])
        XCTAssertEqual(summary.tests.map(\.suspect), [true, false])
        XCTAssertEqual(
            summary.warning(mutationScore: 100),
            "1 test may fail whatever the mutant: it failed for mutants in at least 50% of the 5 files with a killed "
                + "mutant (sum() in 3). Without its failures, the mutation score would be 40%, not 100%."
        )
    }

    // A test that failed in a control run is flaky, so suspect, however few files it failed for mutants in; a flaky
    // test that killed nothing is listed with the control runs only.
    func test_aTestThatFailedInAControlRun_isSuspect_andFlaky() throws {
        let timing = failedTest("timing()", in: "TimingTests.swift")
        let sum = failedTest("sum()", in: "SumTests.swift")
        let clock = failedTest("clock()", in: "ClockTests.swift")
        let controlRuns: [MutationTestOutcome.ControlRun] = [
            .init(outcome: .failed, failedTests: .init(tests: [timing, clock], count: 2, isComplete: true)),
            .init(outcome: .failed, failedTests: .init(tests: [clock], count: 1, isComplete: true)),
            .init(outcome: .passed, failedTests: nil),
        ]

        let summary = try XCTUnwrap(KillingTestSummary(
            of: [kill(in: "A.swift", naming: [timing]), kill(in: "B.swift", naming: [sum])],
            controlRuns: controlRuns
        ))

        XCTAssertEqual(summary.controlRuns, 3)
        XCTAssertEqual(summary.failedControlRuns, 2)
        XCTAssertEqual(summary.failedControlRunsNamingNoTest, 0)
        XCTAssertEqual(summary.flakyTests, [
            .init(name: "clock()", file: "ClockTests.swift", controlRuns: 2),
            .init(name: "timing()", file: "TimingTests.swift", controlRuns: 1),
        ])
        XCTAssertEqual(summary.tests.map(\.name), ["sum()", "timing()"])
        XCTAssertEqual(summary.tests.map(\.failedControlRuns), [0, 1])
        XCTAssertEqual(summary.tests.map(\.suspect), [false, true])
        XCTAssertEqual(summary.suspectOnlyKills, 1)
        XCTAssertEqual(summary.controlRunSentences, [
            "2 of the 3 control runs, with no mutant on and under the same load as the mutants, didn't pass.",
            "A test that failed in one is flaky, so it is suspect: clock() in 2, timing() in 1.",
        ])
        XCTAssertEqual(summary.suspectSentences(mutationScore: 100), [
            "1 suspect test failed in a control run, with no mutant on and under the same load, so may fail whatever "
                + "the mutant.",
            "Only suspect tests were recorded failing for 1 mutant. Without its failures, the mutation score would be "
                + "50%, not 100%.",
            "Leave a flaky test out of mutation runs: skip it while the environment variable IS_MUTER_RUNNING is "
                + "YES, which SwiftMutator sets for the baseline, every mutant's test run and the control runs.",
        ])
    }

    func test_controlRunSentences_sayWhenEveryOnePassed_andNoneWithoutControlRuns() throws {
        let sum = failedTest("sum()")
        let kills = [kill(in: "A.swift", naming: [sum])]
        let passed = MutationTestOutcome.ControlRun(outcome: .passed, failedTests: nil)

        XCTAssertEqual(try XCTUnwrap(KillingTestSummary(of: kills)).controlRunSentences, [])
        XCTAssertEqual(try XCTUnwrap(KillingTestSummary(of: kills, controlRuns: [passed])).controlRunSentences, [
            "The 1 control run, with no mutant on and under the same load as the mutants, passed.",
        ])
        XCTAssertEqual(
            try XCTUnwrap(KillingTestSummary(of: kills, controlRuns: [passed, passed])).controlRunSentences,
            ["All 2 control runs, with no mutant on and under the same load as the mutants, passed."]
        )
        let crashed = MutationTestOutcome.ControlRun(
            outcome: .runtimeError, failedTests: .init(tests: [], count: 0, isComplete: true)
        )
        XCTAssertEqual(try XCTUnwrap(KillingTestSummary(of: kills, controlRuns: [crashed])).controlRunSentences, [
            "The 1 control run, with no mutant on and under the same load as the mutants, didn't pass.",
            "It names no failed test, as a crash or a timeout may not.",
        ])
        XCTAssertEqual(
            try XCTUnwrap(KillingTestSummary(of: kills, controlRuns: [crashed, crashed])).controlRunSentences.last,
            "They name no failed test, as a crash or a timeout may not."
        )
    }

    // Suspect by the rule and flaky at once: each part of the warning names its own.
    func test_theWarning_namesTheFlakyTests_andThoseTheRuleFound_apart() throws {
        let timing = failedTest("timing()", in: "TimingTests.swift")
        let arrival = failedTest("arrival()", in: "ArrivalTests.swift")
        let mutations = (0 ..< 10).map { index in
            kill(in: "F\(index).swift", naming: index < 5 ? [arrival, timing] : [arrival])
        }
        let controlRuns: [MutationTestOutcome.ControlRun] = [
            .init(outcome: .failed, failedTests: .init(tests: [timing], count: 1, isComplete: true)),
            .init(outcome: .passed, failedTests: nil),
        ]

        let summary = try XCTUnwrap(KillingTestSummary(of: mutations, controlRuns: controlRuns))

        XCTAssertEqual(summary.tests.map(\.suspectCell), ["yes", "flaky"])
        XCTAssertEqual(
            summary.warning(mutationScore: 100),
            "2 tests may fail whatever the mutant: 1 failed in a control run, with no mutant on (timing() in 1 of 2), "
                + "and 1 failed for mutants in at least 15% of the 10 files with a killed mutant (arrival() in 10). "
                + "Without their failures, the mutation score would be 0%, not 100%."
        )
        XCTAssertEqual(
            summary.suspectSentences(mutationScore: 100).first,
            "Of 2 suspect tests, 1 failed in a control run, with no mutant on and under the same load, and 1 failed "
                + "for mutants in at least 15% of the 10 files with a killed mutant, as a flaky test or a broad test "
                + "of the mutated code can."
        )
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
}
