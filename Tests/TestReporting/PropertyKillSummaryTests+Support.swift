@testable import muterCore

extension PropertyKillSummaryTests {
    /// Two property tests, one Swift Testing's in SortProperties.swift and one XCTest's, and an example. Killed: 2 by
    /// examples alone, one of them by a run that stopped at its first failed test; 2 by properties alone; 1 by both;
    /// a crash and a kill whose log names no test. Then a survivor, a timeout and a build error.
    static var mutations: [MutationTestOutcome.Mutation] {
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let ordered = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        let roundTrip = FailedTestLine.FailedTest(name: "-[AppTests.ParseProperties testRoundTrip]", location: nil)
        return [
            mutant(.failed, KillingTests(tests: [sum], count: 1, isComplete: true)),
            mutant(.failed, KillingTests(tests: [ordered], count: 1, isComplete: true)),
            mutant(.failed, KillingTests(tests: [sum, ordered], count: 2, isComplete: true)),
            mutant(.failed, KillingTests(tests: [sum], count: 1, isComplete: false)),
            mutant(.failed, KillingTests(tests: [roundTrip], count: 1, isComplete: true)),
            mutant(.runtimeError, nil),
            mutant(.failed, KillingTests(tests: [], count: 0, isComplete: true)),
            mutant(.passed, nil),
            mutant(.timeout, KillingTests(tests: [], count: 0, isComplete: false)),
            mutant(.buildError, nil),
        ]
    }

    typealias KillingTests = MutationTestOutcome.KillingTests

    static func mutant(_ outcome: TestSuiteOutcome, _ killingTests: KillingTests?) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(filePath: "/project/Sources/Sort.swift", position: 3),
            killingTests: killingTests
        )
    }

    func kill(
        naming tests: [FailedTestLine.FailedTest],
        count: Int? = nil,
        isComplete: Bool = true
    ) -> MutationTestOutcome.Mutation {
        Self.mutant(.failed, KillingTests(tests: tests, count: count ?? tests.count, isComplete: isComplete))
    }

    func failedTest(_ name: String, in file: String) -> FailedTestLine.FailedTest {
        .init(name: name, location: "\(file):3:5")
    }

    func identity(_ name: String, in file: String?) -> FailedTestLine.TestIdentity {
        .init(name: name, file: file)
    }
}
