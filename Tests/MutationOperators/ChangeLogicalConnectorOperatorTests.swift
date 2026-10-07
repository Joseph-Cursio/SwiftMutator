@testable import muterCore
import TestingExtensions
import XCTest

final class ChangeLogicalConnectorOperatorTests: MuterTestCase {
    private lazy var sourceWithLogicalOperators = sourceCode(
        fromFileAt: "\(fixturesDirectory)/MutationExamples/LogicalOperator/sampleWithLogicalOperators.swift"
    )!

    private lazy var sampleWithFailuresParsing = sourceCode(
        fromFileAt: "\(fixturesDirectory)/MutationExamples/LogicalOperator/sampleWithFailuresParsing.swift"
    )!

    func test_rewriter() throws {
        let visitor = ChangeLogicalConnectorOperator.Visitor(
            sourceCodeInfo: sourceWithLogicalOperators
        )

        visitor.walk(sourceWithLogicalOperators.code)

        let rewritten = MuterRewriter(visitor.schemataMappings)
            .rewrite(sourceWithLogicalOperators.code)
        AssertSnapshot(formatCode(rewritten.description))
    }

    func test_visitor() throws {
        let visitor = ChangeLogicalConnectorOperator.Visitor(
            sourceCodeInfo: sourceWithLogicalOperators
        )

        visitor.walk(sourceWithLogicalOperators.code)

        let actualSchemata = visitor.schemataMappings
        let expectedSchemata = try SchemataMutationMapping.make(
            (
                source: "\n    // バルーンの表示判定\n    return false && false",
                schemata: [
                    .make(
                        filePath: sourceWithLogicalOperators.path,
                        mutationOperatorId: .logicalOperator,
                        syntaxMutation: "\n    // バルーンの表示判定\n    return false || false",
                        position: MutationPosition(
                            utf8Offset: 256,
                            line: 15,
                            column: 18
                        ),
                        snapshot: .make(
                            before: "&&",
                            after: "||",
                            description: "changed && to ||"
                        )
                    ),
                ]
            ),
            (
                source: "\n    return false && false",
                schemata: [
                    .make(
                        filePath: sourceWithLogicalOperators.path,
                        mutationOperatorId: .logicalOperator,
                        syntaxMutation: "\n    return true && true",
                        position: MutationPosition(
                            utf8Offset: 160,
                            line: 10,
                            column: 17
                        ),
                        snapshot: .make(
                            before: "||",
                            after: "&&",
                            description: "changed || to &&"
                        )
                    ),
                ]
            ),
            (
                source: "\n    return true || true",
                schemata: [
                    .make(
                        filePath: sourceWithLogicalOperators.path,
                        mutationOperatorId: .logicalOperator,
                        syntaxMutation: "\n    return false || false",
                        position: MutationPosition(
                            utf8Offset: 101,
                            line: 6,
                            column: 18
                        ),
                        snapshot: .make(
                            before: "&&",
                            after: "||",
                            description: "changed && to ||"
                        )
                    ),
                ]
            )
        )

        XCTAssertEqual(actualSchemata, expectedSchemata)
    }

    func test_sampleWithFailuresParsing() throws {
        let visitor = ChangeLogicalConnectorOperator.Visitor(
            sourceCodeInfo: sampleWithFailuresParsing
        )

        visitor.walk(sampleWithFailuresParsing.code)

        let rewritten = MuterRewriter(visitor.schemataMappings)
            .rewrite(sampleWithFailuresParsing.code)
        AssertSnapshot(rewritten.description)
    }

    // The reparse of the mutated block was told where the edit is in characters, not UTF-8 bytes.
    // Multi-byte text on an earlier line put the edit before the connector's statement, so the
    // reparse reused that statement unmutated: the mutant was the original, reported as survived.
    func test_changesAConnectorAfterMultiByteText() throws {
        let source = try sourceCode(
            """
            func both(_ a: Bool, _ b: Bool) -> Bool {
                let face = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂"
                print(face)
                return a && b
            }
            """
        )
        let visitor = ChangeLogicalConnectorOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let mutations = visitor.schemataMappings.mutationSchemata.map { $0.syntaxMutation.description.trimmed.inlined }
        XCTAssertEqual(mutations, [#"let face = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂" print(face) return a || b"#])
    }
}
