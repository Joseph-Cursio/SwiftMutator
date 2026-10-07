@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class SwapTernaryOperatorTests: MuterTestCase {
    private lazy var sampleCode = sourceCode(
        fromFileAt: "\(mutationExamplesDirectory)/TernaryOperator/sampleWithTernaryOperator.swift"
    )!

    private lazy var sampleNestedCode = sourceCode(
        fromFileAt: "\(mutationExamplesDirectory)/TernaryOperator/sampleWithNestedTernaryOperator.swift"
    )!

    func test_visitor() throws {
        let visitor = SwapTernaryOperator.Visitor(
            sourceCodeInfo: sampleCode
        )

        visitor.walk(sampleCode.code)

        let actualMappings = visitor.schemataMappings
        let expectedMappings = try SchemataMutationMapping.make(
            filePath: sampleCode.path,
            (
                source: "\n    return a ? \"true\" : \"false\"",
                schemata: [
                    .make(
                        filePath: sampleCode.path,
                        mutationOperatorId: .swapTernary,
                        syntaxMutation: "\n    return a  ? \"false\" :  \"true\" ",
                        position: MutationPosition(
                            utf8Offset: 199,
                            line: 10,
                            column: 32
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "a ? \"true\" : \"false\"",
                            after: "a  ? \"false\" :  \"true\"",
                            description: "swapped ternary operator"
                        )
                    ),
                ]
            ),
            (
                source: "\n    return a ? true : false",
                schemata: [
                    .make(
                        filePath: sampleCode.path,
                        mutationOperatorId: .swapTernary,
                        syntaxMutation: "\n    return a  ? false :  true ",
                        position: MutationPosition(
                            utf8Offset: 120,
                            line: 6,
                            column: 28
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "a ? true : false",
                            after: "a  ? false :  true",
                            description: "swapped ternary operator"
                        )
                    ),
                ]
            )
        )

        XCTAssertEqual(actualMappings, expectedMappings)
    }

    func test_visitor_nestedTernaryOperator() throws {
        let visitor = SwapTernaryOperator.Visitor(
            sourceCodeInfo: sampleNestedCode
        )

        visitor.walk(sampleNestedCode.code)

        let actualMappings = visitor.schemataMappings
        let expectedMappings = try SchemataMutationMapping.make(
            (
                source: "\n    return a ? b ? true : false : false",
                schemata: [
                    .make(
                        filePath: sampleNestedCode.path,
                        mutationOperatorId: .swapTernary,
                        syntaxMutation: "\n    return a  ? false :  b ? true : false ",
                        position: MutationPosition(
                            utf8Offset: 143,
                            line: 6,
                            column: 40
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "a ? b ? true : false : false",
                            after: "a  ? false :  b ? true : false",
                            description: "swapped ternary operator"
                        )
                    ),
                    .make(
                        filePath: sampleNestedCode.path,
                        mutationOperatorId: .swapTernary,
                        syntaxMutation: "\n    return a ? b  ? false :  true : false",
                        position: MutationPosition(
                            utf8Offset: 136,
                            line: 6,
                            column: 33
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "b ? true : false",
                            after: "b  ? false :  true",
                            description: "swapped ternary operator"
                        )
                    ),
                ]
            )
        )

        XCTAssertEqual(actualMappings, expectedMappings)
    }

    func test_rewriter() {
        let visitor = SwapTernaryOperator.Visitor(
            sourceCodeInfo: sampleNestedCode
        )

        visitor.walk(sampleNestedCode.code)

        let rewriter = MuterRewriter(visitor.schemataMappings).rewrite(sampleNestedCode.code)

        AssertSnapshot(formatCode(rewriter.description))
    }

    func test_shouldIgnoreComplexExpressions() throws {
        let source = try sourceCode(
            """
            func complexExpression(_ a: Any, _ b: Any) -> Any? {
                return a.isEmpty ? nil : a as [String]
            }
            """
        )

        let visitor = SwapTernaryOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        XCTAssertTrue(visitor.schemataMappings.isEmpty)
    }

    // An else-branch with more than one term is several sibling children of the unresolved
    // sequence. The swap used to bail out and return the node unchanged, yet still register it as
    // a mutant: an identical copy of the original was switched in and reported as "survived".
    func test_swapsAnElseBranchWithSeveralTerms() throws {
        let mutations = try swappedMutations(of: """
        func join(_ flag: Bool, _ a: String, _ b: String) -> String {
            return flag ? a + b : a + "/" + b
        }
        """)

        XCTAssertEqual(mutations, [#"return flag ? a + "/" + b : a + b"#])
    }

    // #308: when the else-branch is a comparison, swapping only its first term produced
    // `x < y < d`, which does not compile. The whole else-branch must move.
    func test_swapsAComparisonElseBranchIntoValidSwift() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ x: Int, _ y: Int, _ p: Int, _ q: Int) -> Bool {
            return x == y ? p < q : x < y
        }
        """)

        XCTAssertEqual(mutations, ["return x == y ? x < y : p < q"])
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // The reparse of the mutated block must be told where the edit is in UTF-8 bytes. It was told
    // in characters, so multi-byte text earlier in the block put the edit before the statement
    // being mutated. The reparse then reused that statement unmutated and appended the swap's
    // leftover tail, `return flag ? face : "none"ce`, which does not compile.
    func test_swapsATernaryAfterMultiByteText() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ flag: Bool) -> String {
            let face = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂"
            return flag ? face : "none"
        }
        """)

        XCTAssertEqual(mutations, [#"let face = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂" return flag ? "none" : face"#])
    }

    // The swap is three bytes longer than the ternary, but the reparse was told that the text after
    // it had not moved. A statement that now started where another used to start was taken to be
    // that other one: here `ab` was dropped and `ef` appeared twice.
    func test_keepsTheStatementsAfterATernaryThatGrows() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ flag: Bool, _ ab: Int, _ cd: Int, _ ef: Int) {
            let value = flag ? 1 : 2;ab;cd;ef
        }
        """)

        XCTAssertEqual(mutations, ["let value = flag ? 2 : 1 ;ab;cd;ef"])
    }

    /// Each mutation's text with runs of whitespace collapsed, so the assertions read like source.
    private func swappedMutations(of text: String) throws -> [String] {
        let source = try sourceCode(text)
        let visitor = SwapTernaryOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)

        return visitor.schemataMappings.mutationSchemata.map {
            $0.syntaxMutation.description
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
    }
}
