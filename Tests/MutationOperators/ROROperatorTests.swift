@testable import muterCore
import TestingExtensions
import XCTest

final class ROROperatorTests: MuterTestCase {
    private lazy var sourceWithConditionalLogic = sourceCode(
        fromFileAt: "\(mutationExamplesDirectory)/NegateConditionals/sampleWithConditionalOperators.swift"
    )!

    private lazy var sourceWithoutMutableCode = sourceCode(
        fromFileAt: "\(fixturesDirectory)/sourceWithoutMutableCode.swift"
    )!

    private lazy var conditionalConformanceConstraints = sourceCode(
        fromFileAt: "\(mutationExamplesDirectory)/NegateConditionals/conditionalConformanceConstraints.swift"
    )!

    func test_visitor() throws {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: sourceWithConditionalLogic.code)
        )

        visitor.walk(sourceWithConditionalLogic.code)

        let actualSchematas = visitor.schemataMappings

        AssertSnapshot(actualSchematas.description)
    }

    func test_visitorOnFileWithoutOperator() {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: sourceWithoutMutableCode
        )

        visitor.walk(sourceWithoutMutableCode.code)

        XCTAssertTrue(visitor.schemataMappings.isEmpty)
    }

    func test_ignoresFunctionDeclarations() throws {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: sourceWithConditionalLogic
        )

        visitor.walk(sourceWithConditionalLogic.code)

        XCTAssertFalse(visitor.schemataMappings.codeBlocks.contains("func < "))
    }

    func test_ignoresConditionalConformancesConstraints() {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: conditionalConformanceConstraints
        )

        visitor.walk(conditionalConformanceConstraints.code)

        XCTAssertTrue(visitor.schemataMappings.isEmpty)
    }

    func test_rewriter() {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: sourceWithConditionalLogic
        )

        visitor.walk(sourceWithConditionalLogic.code)

        let actualSchematas = visitor.schemataMappings
        let rewriter = MuterRewriter(actualSchematas).rewrite(sourceWithConditionalLogic.code)

        AssertSnapshot(formatCode(rewriter.description))
    }

    func test_charOffsetCrash() throws {
        let source = try sourceCode(
            """
            if value == "バルーンの表示判定" {

            }
            """
        )

        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file.swift", code: source)
        )

        visitor.walk(source)

        let rewritten = MuterRewriter(visitor.schemataMappings)
            .rewrite(source)
        AssertSnapshot(formatCode(rewritten.description))
    }

    // The reparse of the mutated block was told where the edit is in characters, not UTF-8 bytes.
    // Multi-byte text on an earlier line put the edit before the comparison's statement, so the
    // reparse reused that statement unmutated: the mutant was the original, reported as survived.
    func test_mutatesAComparisonAfterMultiByteText() throws {
        let source = try sourceCode(
            """
            func matches(_ a: Int, _ b: Int) -> Bool {
                let label = "バルーンの表示判定"
                print(label)
                return a == b
            }
            """
        )
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let mutations = visitor.schemataMappings.mutationSchemata.map { $0.syntaxMutation.description.trimmed.inlined }
        XCTAssertEqual(mutations, [#"let label = "バルーンの表示判定" print(label) return a != b"#])
    }
}
