@testable import muterCore

extension KillingTestSummaryTests {
    /// A Swift Testing test whose issue was recorded in `file`, or, with no file, one without a location.
    func failedTest(_ name: String, in file: String? = "SumTests.swift", line: Int = 3) -> FailedTestLine.FailedTest {
        .init(name: name, location: file.map { "\($0):\(line):5" })
    }

    /// A mutant in `file` a failed test killed, with `tests` recorded failing: `count` of them, all by default.
    func kill(
        in file: String,
        naming tests: [FailedTestLine.FailedTest]?,
        line: Int = 1,
        count: Int? = nil,
        isComplete: Bool = true
    ) -> MutationTestOutcome.Mutation {
        mutant(
            .failed,
            in: file,
            killingTests: tests.map { .init(tests: $0, count: count ?? $0.count, isComplete: isComplete) },
            line: line
        )
    }

    func mutant(
        _ outcome: TestSuiteOutcome,
        in file: String,
        killingTests: MutationTestOutcome.KillingTests?,
        line: Int = 1
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(filePath: "/project/Sources/\(file)", position: .init(integerLiteral: line)),
            killingTests: killingTests
        )
    }
}
