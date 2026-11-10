@testable import muterCore

enum FileReportProvider {

    static var expectedFileReport1: FileReport {
        .init(
            fileName: "a module.swift",
            path: "/tmp/a module.swift",
            mutationScore: 100,
            appliedOperators: [
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/a module.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .failed,
                    path: "/tmp/a module.swift"
                ),
            ],
            relativePath: "/tmp/a module.swift"
        )
    }

    static var expectedFileReport2: FileReport {
        .init(
            fileName: "file 4.swift",
            path: "/tmp/file 4.swift",
            mutationScore: 0,
            appliedOperators: [
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file 4.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .passed,
                    path: "/tmp/file 4.swift"
                ),
            ],
            relativePath: "/tmp/file 4.swift"
        )
    }

    static var expectedFileReport3: FileReport {
        .init(
            fileName: "file1.swift",
            path: "/tmp/file1.swift",
            mutationScore: 66,
            appliedOperators: [
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file1.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .failed,
                    path: "/tmp/file1.swift"
                ),
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file1.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .failed,
                    path: "/tmp/file1.swift"
                ),
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file1.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .passed,
                    path: "/tmp/file1.swift"
                ),
            ],
            relativePath: "/tmp/file1.swift"
        )
    }

    static var expectedFileReport4: FileReport {
        .init(
            fileName: "file2.swift",
            path: "/tmp/file2.swift",
            mutationScore: 100,
            appliedOperators: [
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .removeSideEffects,
                        filePath: "/tmp/file2.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .failed,
                    path: "/tmp/file2.swift"
                ),
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .removeSideEffects,
                        filePath: "/tmp/file2.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .failed,
                    path: "/tmp/file2.swift"
                ),
            ],
            relativePath: "/tmp/file2.swift"
        )
    }

    static var expectedFileReport5: FileReport {
        .init(
            fileName: "file3.swift",
            path: "/tmp/file3.swift",
            mutationScore: 33,
            appliedOperators: [
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file3.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .failed,
                    path: "/tmp/file3.swift"
                ),
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file3.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .passed,
                    path: "/tmp/file3.swift"
                ),
                AppliedMutationOperator.make(
                    mutationPoint: MutationPoint.make(
                        mutationOperatorId: .ror,
                        filePath: "/tmp/file3.swift",
                        position: .firstPosition
                    ),
                    mutationSnapshot: .make(
                        before: "==",
                        after: "!=",
                        description: "changed from == to !="
                    ),
                    testSuiteOutcome: .passed,
                    path: "/tmp/file3.swift"
                ),
            ],
            relativePath: "/tmp/file3.swift"
        )
    }
}
