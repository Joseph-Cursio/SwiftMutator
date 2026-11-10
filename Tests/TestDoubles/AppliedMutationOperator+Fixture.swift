@testable import muterCore

extension AppliedMutationOperator {
    static func make(
        mutationPoint: MutationPoint = .make(),
        mutationSnapshot: MutationOperator.Snapshot = .make(),
        testSuiteOutcome: TestSuiteOutcome = .passed,
        killingTests: MutationTestOutcome.KillingTests? = nil,
        killedOnlyBySuspectTests: Bool = false,
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

extension FileReport {
    static func make(
        name: String,
        path: String,
        mutationScore: Int,
        appliedOperators: [AppliedMutationOperator]
    ) -> Self {
        Self(
            fileName: name,
            path: path,
            mutationScore: mutationScore,
            appliedOperators: appliedOperators
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
