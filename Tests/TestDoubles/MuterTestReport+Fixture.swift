@testable import muterCore
import SwiftSyntax

extension MuterTestReport {
    static func make(
        outcome: MutationTestOutcome = .make()
    ) -> MuterTestReport {
        .init(from: outcome)
    }
}

extension MuterTestReport.AppliedMutationOperator {
    static func make(
        mutationPoint: MutationPoint = .make(),
        mutationSnapshot: MutationOperator.Snapshot = .make(),
        testSuiteOutcome: TestSuiteOutcome = .passed,
        killingTests: MutationTestOutcome.KillingTests? = nil,
        killedOnlyBySuspectTests: Bool? = nil,
        reusedFrom: ReusedFrom? = nil,
        path: String? = nil
    ) -> Self {
        Self(
            mutationPoint: mutationPoint,
            mutationSnapshot: mutationSnapshot,
            testSuiteOutcome: testSuiteOutcome,
            killingTests: killingTests,
            killedOnlyBySuspectTests: killedOnlyBySuspectTests,
            reusedFrom: reusedFrom,
            path: path
        )
    }
}

extension MutationOperator.Snapshot {
    static func make(
        before: String = "",
        after: String = "",
        description: String = ""
    ) -> Self {
        Self(
            before: before,
            after: after,
            description: description
        )
    }
}

extension MuterTestReport.FileReport {
    static func make(
        name: String,
        path: String,
        mutationScore: Int,
        appliedOperators: [MuterTestReport.AppliedMutationOperator]
    ) -> Self {
        Self(
            fileName: name,
            path: path,
            mutationScore: mutationScore,
            appliedOperators: appliedOperators
        )
    }
}

extension MuterTestReport.AppliedMutationOperator {
    static func make(
        mutationOperator: MutationOperator.Id = .logicalOperator,
        position: SwiftSyntax.SourceLocation = .init(integerLiteral: 0),
        mutationSnapshot: MutationOperator.Snapshot = .null,
        testOutcome: TestSuiteOutcome = .passed
    ) -> Self {
        Self(
            mutationPoint: .make(
                mutationOperatorId: mutationOperator,
                filePath: "filePath",
                position: MutationPosition(sourceLocation: position)
            ),
            mutationSnapshot: mutationSnapshot,
            testSuiteOutcome: testOutcome
        )
    }
}

extension MutationPoint {
    static func make(
        mutationOperatorId: MutationOperator.Id = .logicalOperator,
        filePath: String = "",
        position: MutationPosition = 10
    ) -> Self {
        Self(
            mutationOperatorId: mutationOperatorId,
            filePath: filePath,
            position: position
        )
    }
}
