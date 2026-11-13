@testable import muterCore
import TestingExtensions
import XCTest

/// RelationalOperatorReplacement gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set: an
/// ordering comparison's operator swapped for `!=` or `==`, and the comparison replaced with `false` or `true`; an
/// equality check replaced with `true`, and in a second mutant with `false`.
final class ROROperatorTests: MuterTestCase {
    private lazy var sourceWithConditionalLogic = fixtureSource(
        at: "\(mutationExamplesDirectory)/RelationalOperatorReplacement/sampleWithConditionalOperators.swift"
    )

    private lazy var sourceWithoutMutableCode = fixtureSource(
        at: "\(fixturesDirectory)/sourceWithoutMutableCode.swift"
    )

    private lazy var conditionalConformanceConstraints = fixtureSource(
        at: "\(mutationExamplesDirectory)/RelationalOperatorReplacement/conditionalConformanceConstraints.swift"
    )

    func visitor(walking code: String, coverage: FileCoverage = .empty) throws -> MuterVisitor {
        let source = try sourceCode(code)
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.walk(source)
        return visitor
    }

    /// What each mutant makes of its statement list, in the order of the file, its spacing collapsed.
    func mutants(of code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { collapsingWhitespace($0.syntaxMutation.description) }
    }

    /// What each mutant puts in place of the code it replaces, in the order of the file.
    func changes(in code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { "\($0.snapshot.before) → \($0.snapshot.after)" }
    }

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
        XCTAssertFalse(
            visitor.schemataMappings.mutationSchemata.contains { $0.syntaxMutation.description.contains("func !=") }
        )
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

        let mutations = visitor.schemataMappings.mutationSchemata.map(\.syntaxMutation.description.trimmed.inlined)
        XCTAssertEqual(mutations, [
            #"let label = "バルーンの表示判定" print(label) return true"#,
            #"let label = "バルーンの表示判定" print(label) return false"#,
        ])
    }

    // MARK: Each comparison's mutants

    func test_eachOrderingComparison_getsItsSwap_andItsConstant() throws {
        XCTAssertEqual(try changes(in: "func f() -> Bool { a < b }"), ["< → !=", "a < b → false"])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a > b }"), ["> → !=", "a > b → false"])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a <= b }"), ["a <= b → true", "<= → =="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a >= b }"), ["a >= b → true", ">= → =="])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { a < b }"), ["a != b", "false"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { a >= b }"), ["true", "a == b"])
    }

    func test_eachEqualityCheck_getsBothConstants_andNoSwap() throws {
        XCTAssertEqual(try changes(in: "func f() -> Bool { a == b }"), ["a == b → true", "a == b → false"])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a != b }"), ["a != b → true", "a != b → false"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { return a != b }"), ["return true", "return false"])
    }

    // Nothing swaps an identity check, and an operator the standard library doesn't declare could be anything.
    func test_identityChecksAndOtherOperators_areLeftAlone() throws {
        for code in [
            "func f() -> Bool { a === b }",
            "func f() -> Bool { a !== b }",
            "func f() -> Bool { a <=> b }",
            "func f() -> Bool { a ~= b }",
            "func f() -> Int { a + b }",
        ] {
            XCTAssertEqual(try changes(in: code), [], code)
        }
    }

    // `true` is placed where the comparison starts, and `false` where it ends, so that each has a switch of its own,
    // apart from the swap's, at the operator.
    func test_eachMutant_hasAPlaceAndASwitchOfItsOwn_andItsSnapshotNamesTheComparison() throws {
        let equality = try visitor(walking: """
        func f() -> Bool {
            return a.count == b
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(equality.map(\.mutationOperatorId), [.ror, .ror])
        XCTAssertEqual(equality.map(\.position.line), [2, 2])
        XCTAssertEqual(equality.map(\.position.column), [12, 24])
        XCTAssertEqual(equality.map(\.snapshot), [
            .init(before: "a.count == b", after: "true", description: "replaced the comparison with true"),
            .init(before: "a.count == b", after: "false", description: "replaced the comparison with false"),
        ])
        XCTAssertNotEqual(equality[0].id, equality[1].id)

        let ordering = try visitor(walking: """
        func f() -> Bool {
            return a.count < b
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(ordering.map(\.position.column), [20, 23])
        XCTAssertEqual(ordering.map(\.snapshot), [
            .init(before: "<", after: "!=", description: "changed < to !="),
            .init(before: "a.count < b", after: "false", description: "replaced the comparison with false"),
        ])
        XCTAssertEqual(
            MutantKey.keys(for: equality + ordering, under: URL(fileURLWithPath: "/path/to")).map(\.occurrence),
            [0, 0, 0, 0]
        )
    }

    // MARK: Where the shared rules apply

    func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
