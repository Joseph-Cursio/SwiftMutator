import Foundation
@testable import muterCore

extension ReadableReportTests {
    func mutant(
        _ outcome: TestSuiteOutcome,
        _ path: String,
        line: Int,
        column: Int,
        _ snapshot: MutationOperator.Snapshot = .make(before: "==", after: "!=", description: "changed == to !=")
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(
                mutationOperatorId: .ror,
                filePath: mutatedCopy.path + "/" + path,
                position: MutationPosition(utf8Offset: 0, line: line, column: column)
            ),
            snapshot: snapshot,
            originalProjectDirectoryUrl: project,
            mutatedProjectDirectoryURL: mutatedCopy
        )
    }

    func outcome(
        _ mutations: [MutationTestOutcome.Mutation],
        digests: [String: String]? = nil
    ) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutations,
            projectPath: project.path,
            mutatedProjectPath: mutatedCopy.path,
            sourceDigests: digests
        )
    }

    /// Reads `rules` as the original Sources/Rules.swift, and nothing else.
    func readingRules() -> ReadFile {
        { [rules, project] path in path == project.path + "/Sources/Rules.swift" ? Data(rules.utf8) : nil }
    }
}
