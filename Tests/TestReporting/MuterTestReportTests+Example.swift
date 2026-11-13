@testable import muterCore

extension MuterTestReportTests {
    var exampleMutationTestResults: [MutationTestOutcome.Mutation] {
        [
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file1.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file1.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file1.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .removeSideEffects,
                    filePath: "/tmp/file2.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .removeSideEffects,
                    filePath: "/tmp/file2.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file3.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file3.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file3.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file 4.swift", // this file name intentionally has a space in it
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
        ]
    }
}
