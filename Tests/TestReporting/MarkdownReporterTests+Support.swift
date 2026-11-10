@testable import muterCore
import TestingExtensions
import XCTest

extension MarkdownReporterTests {
    /// A mutant in `Sources/Rules.swift`.
    func mutant(
        _ outcome: TestSuiteOutcome,
        line: Int,
        column: Int = 9,
        description: String = "changed == to !="
    ) -> MutationTestOutcome.Mutation {
        mutant(outcome, "Sources/Rules.swift", line: line, column: column, description: description)
    }

    func mutant(
        _ outcome: TestSuiteOutcome,
        _ path: String,
        line: Int,
        column: Int = 9,
        description: String = "changed == to !="
    ) -> MutationTestOutcome.Mutation {
        .make(
            testSuiteOutcome: outcome,
            point: .make(
                mutationOperatorId: .ror,
                filePath: mutatedCopy.path + "/" + path,
                position: MutationPosition(utf8Offset: 0, line: line, column: column)
            ),
            snapshot: .make(before: "==", after: "!=", description: description),
            originalProjectDirectoryUrl: project,
            mutatedProjectDirectoryURL: mutatedCopy,
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: column, occurrence: 0)
        )
    }

    func report(_ outcome: MutationTestOutcome) -> String {
        MarkdownReporter().report(from: outcome)
    }
}
