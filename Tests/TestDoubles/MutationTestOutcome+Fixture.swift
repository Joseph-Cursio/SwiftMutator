import Foundation
@testable import muterCore

extension MutationTestOutcome {
    static func make(
        mutations: [Mutation] = [],
        coverage: Coverage = .null,
        failUnder: Double? = nil,
        propertyTests: [String] = []
    ) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            coverage: coverage,
            failUnder: failUnder,
            propertyTests: propertyTests
        )
    }

    /// An outcome with a mutant for each of `outcomes`, in a file of its own, as a run with `failUnder` reports it.
    static func make(
        _ outcomes: [TestSuiteOutcome],
        failUnder: Double? = nil,
        shards: ShardScope? = nil,
        mutant: String? = nil
    ) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: outcomes.map { .make(testSuiteOutcome: $0) },
            shards: shards,
            mutant: mutant,
            failUnder: failUnder
        )
    }
}

extension EarlyEnd {
    /// Mutation testing that stopped after testing a mutant with each of `tested`, of `discovered`.
    static func make(
        reason: ResultsEnd.Reason = .interrupted,
        detail: String? = nil,
        tested: [TestSuiteOutcome] = [.failed, .passed],
        discovered: Int = 4,
        reused: Int = 0
    ) -> EarlyEnd {
        EarlyEnd(
            reason: reason,
            detail: detail,
            outcome: MutationTestOutcome(mutations: tested.map { .make(testSuiteOutcome: $0) }),
            discovered: discovered,
            reused: reused
        )
    }
}

extension OneMutantRun {
    /// A SwapTernary mutant killed by one test in 4.2 s, under a 30 s limit, in a copy whose path holds a space and a
    /// quote.
    static func make(
        outcome: TestSuiteOutcome = .failed,
        killingTests: MutationTestOutcome.KillingTests? = .init(
            tests: [FailedTestLine.FailedTest(name: "picksB()", location: "BarTests.swift:3:5")],
            count: 1,
            isComplete: true
        ),
        testLog: String = "✘ Test picksB() recorded an issue at BarTests.swift:3:5\n\n✘ Test run with 1 test failed.\n",
        logPath: String? = "/logs/Oct 4/SwapTernary @ Bar.swift-12-9 1a2b.log",
        buildSystem: BuildSystem = .swift,
        testCommand: [String] = ["/usr/bin/swift", "test", "Flag with space"]
    ) -> OneMutantRun {
        OneMutantRun(
            key: MutantKey(
                path: "Sources/Foo/Bar.swift", mutationOperatorId: .swapTernary, line: 12, column: 9, occurrence: 0
            ),
            switchID: "Bar_1a2b_SwapTernary_12_9_412",
            snapshot: MutationOperator.Snapshot(
                before: "a ? b : c",
                after: "a ? c : b",
                description: "swapped ternary operator"
            ),
            change: ["-12:     return a ? b : c", "+12:     return a ? c : b"],
            outcome: outcome,
            killingTests: killingTests,
            seconds: 4.23,
            timeoutSeconds: 30,
            testLog: testLog,
            logPath: logPath,
            mutatedProject: "/work/Foo's copy/Foo_mutant",
            buildSystem: buildSystem,
            testCommand: testCommand
        )
    }
}

extension ResumeSummary {
    static func make(
        path: String = "/logs/results.jsonl",
        reused: Int = 2,
        toTest: Int = 2,
        retestedBecause: [ResumePlan.Reason: Int] = [.notRecorded: 2],
        noLongerDiscovered: Int = 0,
        discoveredBefore: Int? = nil,
        coverageChange: ResumeCheck.CoverageChange? = nil,
        forced: [String] = [],
        waived: [String] = [],
        testPlanCopy: String? = nil,
        notices: [String] = [],
        isReuse: Bool = false,
        otherFilesChanged: [ProjectTree.FileChange] = [],
        testFilesChanged: Int = 0,
        selectionChange: String? = nil
    ) -> ResumeSummary {
        ResumeSummary(
            path: path,
            isReuse: isReuse,
            reused: reused,
            toTest: toTest,
            retestedBecause: retestedBecause,
            noLongerDiscovered: noLongerDiscovered,
            // As many as this run discovers, unless a test says otherwise.
            discoveredBefore: discoveredBefore ?? reused + toTest,
            coverageChange: coverageChange,
            forced: forced,
            waived: waived,
            testPlanCopy: testPlanCopy,
            notices: notices,
            otherFilesChanged: otherFilesChanged,
            testFilesChanged: testFilesChanged,
            selectionChange: selectionChange
        )
    }
}

extension MutationTestOutcome.Mutation {
    static func make(
        testSuiteOutcome: TestSuiteOutcome = .passed,
        point: MutationPoint = .make(),
        snapshot: MutationOperator.Snapshot = .null,
        originalProjectDirectoryUrl: URL = URL(fileURLWithPath: ""),
        mutatedProjectDirectoryURL: URL = URL(fileURLWithPath: ""),
        killingTests: MutationTestOutcome.KillingTests? = nil,
        reusedFrom: ReusedFrom? = nil,
        key: MutantKey? = nil,
        durationSeconds: Double? = nil
    ) -> Self {
        Self(
            testSuiteOutcome: testSuiteOutcome,
            mutationPoint: point,
            mutationSnapshot: snapshot,
            originalProjectDirectoryUrl: originalProjectDirectoryUrl,
            mutatedProjectDirectoryURL: mutatedProjectDirectoryURL,
            killingTests: killingTests,
            reusedFrom: reusedFrom,
            key: key,
            durationSeconds: durationSeconds
        )
    }
}

extension MutationTestOutcome.KillingTests {
    /// A run that exited by itself without a line that shows a failed test.
    static let noneNamed = Self(tests: [], count: 0, isComplete: true)
}

extension MutationTestOutcome {
    /// Killed mutants in 11 files with the tests that failed for them, as runs record them: 14 tests, the widest in 9
    /// files, so none is suspect. One run stopped at its first failed test, one kill names no test and one has none
    /// recorded; a crash, a time-out and a survivor aren't counted. One test is XCTest's, and one's name is longer
    /// than the plain report shows.
    static var withKillingTests: MutationTestOutcome {
        let shared = FailedTestLine.FailedTest(name: "parsesEveryRule()", location: "ParserTests.swift:12:9")
        let longName = FailedTestLine.FailedTest(
            name: #""adding every number in a long list gives the same total in any order""#,
            location: "File02Tests.swift:8:5"
        )
        let xctest = FailedTestLine.FailedTest(name: "-[AppTests.ParserTests testParsesEmptyInput]", location: nil)
        let everyFile = (1 ... 11).map { file in
            mutant(
                .failed,
                file,
                3,
                file <= 9
                    ? KillingTests(tests: [focused(file), shared], count: 2, isComplete: true)
                    : KillingTests(tests: [focused(file)], count: 1, isComplete: true)
            )
        }
        return .make(mutations: everyFile + [
            mutant(.failed, 1, 7, KillingTests(tests: [focused(1)], count: 3, isComplete: false)),
            mutant(.failed, 2, 9, KillingTests(tests: [longName, focused(2)], count: 2, isComplete: true)),
            mutant(.failed, 3, 12, .noneNamed),
            mutant(.failed, 4, 15, nil),
            mutant(.runtimeError, 5, 18, KillingTests(tests: [focused(5)], count: 1, isComplete: true)),
            mutant(.passed, 6, 21, nil),
            mutant(.failed, 7, 24, KillingTests(tests: [xctest], count: 1, isComplete: true)),
            mutant(.timeout, 8, 27, KillingTests(tests: [], count: 0, isComplete: false)),
        ])
    }

    /// Killed mutants in 12 files with two suspect tests: timing() failed for a mutant in each, order() in 10. The
    /// kills in files 1 to 6 name a focused test too; those in files 7 to 12 name only suspects, and the run in file
    /// 12 stopped at its first failed test, so the score without them is a lower bound. A crash only timing() failed
    /// for stays a kill, and one mutant survived.
    static var withSuspectTests: MutationTestOutcome {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let order = FailedTestLine.FailedTest(name: "order()", location: "OrderTests.swift:4:5")
        let everyFile = (1 ... 12).map { file in
            let tests = (file <= 6 ? [focused(file)] : []) + [timing] + (file >= 2 ? [order] : [])
            return file == 12
                ? mutant(.failed, file, 3, KillingTests(tests: [timing], count: 1, isComplete: false))
                : mutant(.failed, file, 3, KillingTests(tests: tests, count: tests.count, isComplete: true))
        }
        return .make(mutations: everyFile + [
            mutant(.runtimeError, 7, 8, KillingTests(tests: [timing], count: 1, isComplete: true)),
            mutant(.passed, 8, 12, nil),
        ])
    }
}

private extension MutationTestOutcome {
    /// The test that fails for a mutant in `file` alone.
    static func focused(_ file: Int) -> FailedTestLine.FailedTest {
        FailedTestLine.FailedTest(
            name: String(format: "focused%02d()", file),
            location: String(format: "File%02dTests.swift:3:5", file)
        )
    }

    /// A mutant on `line` of `file`, in the copy of a project at /tmp/project, with `killingTests` recorded.
    static func mutant(
        _ outcome: TestSuiteOutcome,
        _ file: Int,
        _ line: Int,
        _ killingTests: KillingTests?
    ) -> Mutation {
        Mutation.make(
            testSuiteOutcome: outcome,
            point: .make(
                filePath: String(format: "/tmp/project_mutated/Sources/File%02d.swift", file),
                position: .init(integerLiteral: line)
            ),
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/tmp/project"),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/tmp/project_mutated"),
            killingTests: killingTests
        )
    }
}
