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
                        syntaxMutation: "\n    return a ? \"false\" :  \"true\" ",
                        position: MutationPosition(
                            utf8Offset: 199,
                            line: 10,
                            column: 32
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "a ? \"true\" : \"false\"",
                            after: "a ? \"false\" :  \"true\"",
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
                        syntaxMutation: "\n    return a ? false :  true ",
                        position: MutationPosition(
                            utf8Offset: 120,
                            line: 6,
                            column: 28
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "a ? true : false",
                            after: "a ? false :  true",
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
                        syntaxMutation: "\n    return a ? false :  b ? true : false ",
                        position: MutationPosition(
                            utf8Offset: 143,
                            line: 6,
                            column: 40
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "a ? b ? true : false : false",
                            after: "a ? false :  b ? true : false",
                            description: "swapped ternary operator"
                        )
                    ),
                    .make(
                        filePath: sampleNestedCode.path,
                        mutationOperatorId: .swapTernary,
                        syntaxMutation: "\n    return a ? b ? false :  true : false",
                        position: MutationPosition(
                            utf8Offset: 136,
                            line: 6,
                            column: 33
                        ),
                        snapshot: MutationOperator.Snapshot(
                            before: "b ? true : false",
                            after: "b ? false :  true",
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
    // being mutated. The reparse then reused that statement unmutated and appended the leftover end
    // of the swap's text after it, which does not compile.
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
    // that other one: here `ab` was dropped and `ef` appeared twice. `:2` is unspaced so that the
    // swap, which spaces it, grows by the length of each statement after it.
    func test_keepsTheStatementsAfterATernaryThatGrows() throws {
        let mutations = try swappedMutations(of: """
        func pick(_ flag: Bool, _ ab: Int, _ cd: Int, _ ef: Int) {
            let value = flag ? 1 :2;ab;cd;ef
        }
        """)

        XCTAssertEqual(mutations, ["let value = flag ? 2 : 1 ;ab;cd;ef"])
    }

    // A comment after the ternary can be all that separates it from the next statement. The swap
    // put one space in place of the last term's trailing trivia, so the comment was lost and
    // `record(flag)` joined the ternary's statement, which does not compile.
    func test_keepsTheCommentAfterATernary() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ flag: Bool) {
            _ = flag ? 1 : 2 /* one
            two */ record(flag)
        }
        """)

        XCTAssertEqual(mutations.map(collapsingWhitespace), ["_ = flag ? 2 : 1 /* one two */ record(flag)"])
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // The same with an else-branch of several terms: the trivia to keep is the last term's.
    func test_keepsTheCommentAfterATernaryWithSeveralElseTerms() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ flag: Bool, _ a: Int, _ b: Int) {
            _ = flag ? 1 : a + b /* one
            two */ record(flag)
        }
        """)

        XCTAssertEqual(mutations.map(collapsingWhitespace), ["_ = flag ? a + b : 1 /* one two */ record(flag)"])
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // An else-branch can touch the token after it, as in `(a < b)else`. Moved there, a then-branch
    // that ends in a name joined that token into one: `delse`.
    func test_keepsTheSwappedTernaryApartFromTheTokenAfterIt() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ c: Bool, _ d: Bool, _ a: Int, _ b: Int) -> Int {
            guard c ? d : (a < b)else { return 0 }
            return 1
        }
        """)

        XCTAssertEqual(mutations.map(collapsingWhitespace), ["guard c ? (a < b) : d else { return 0 } return 1"])
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // A `//` comment after the condition ends at the line break, which is the leading trivia of the
    // `?` that starts the next line. The swap put one space in place of it, so the swapped ternary
    // became part of the comment, leaving `return flag`.
    func test_keepsTheLineBreakBeforeATernarysQuestionMark() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ flag: Bool) -> Int {
            return flag // decides
                ? 1
                : 2
        }
        """)

        XCTAssertEqual(mutations.map(codeTokens), ["return flag ? 2 : 1"])
    }

    /// Each mutation's text with runs of whitespace collapsed, so the assertions read like source.
    private func swappedMutations(of text: String) throws -> [String] {
        try swappedMutationTexts(of: text).map(collapsingWhitespace)
    }

    /// Each mutation's text as it is compiled.
    private func swappedMutationTexts(of text: String) throws -> [String] {
        let source = try sourceCode(text)
        let visitor = SwapTernaryOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)

        return visitor.schemataMappings.mutationSchemata.map(\.syntaxMutation.description)
    }

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The tokens a compiler sees, without comments or whitespace.
    private func codeTokens(_ text: String) -> String {
        Parser.parse(source: text)
            .tokens(viewMode: .sourceAccurate)
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
