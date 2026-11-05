@testable import muterCore
import TestingExtensions
import XCTest

/// RelationalBoundary moves an ordering comparison's boundary: `<` to `<=` and back, `>` to `>=` and back. It finds its
/// operators as RelationalOperatorReplacement does, so only in a binary expression, never in a declaration or a
/// `where` clause.
final class RelationalBoundaryOperatorTests: MuterTestCase {
    private lazy var sourceWithConditionalLogic = fixtureSource(
        at: "\(mutationExamplesDirectory)/RelationalOperatorReplacement/sampleWithConditionalOperators.swift"
    )

    private lazy var conditionalConformanceConstraints = fixtureSource(
        at: "\(mutationExamplesDirectory)/RelationalOperatorReplacement/conditionalConformanceConstraints.swift"
    )

    private lazy var sourceWithoutMutableCode = fixtureSource(
        at: "\(fixturesDirectory)/sourceWithoutMutableCode.swift"
    )

    // One mutant for each ordering operator, and none for `==` or `!=`, which have no boundary to move.
    func test_eachOrderingOperator_becomesItsBoundary_andEqualityIsLeftAlone() {
        let visitor = RelationalBoundaryOperator.Visitor(sourceCodeInfo: sourceWithConditionalLogic)

        visitor.walk(sourceWithConditionalLogic.code)

        let mutants = visitor.schemataMappings.mutationSchemata
            .sorted { $0.position.line < $1.position.line }
            .map { "\($0.position.line): \($0.snapshot.before) → \($0.snapshot.after)" }
        XCTAssertEqual(mutants, ["5: >= → >", "6: <= → <", "7: < → <=", "8: > → >="])
        XCTAssertEqual(
            Set(visitor.schemataMappings.mutationSchemata.map(\.mutationOperatorId)),
            [.relationalBoundary]
        )
        XCTAssertEqual(
            visitor.schemataMappings.mutationSchemata.map(\.snapshot.description).sorted(),
            ["changed < to <=", "changed <= to <", "changed > to >=", "changed >= to >"]
        )
    }

    // The mutant's code is the comparison with its operator changed and its operands kept.
    func test_theMutatedCode_comparesTheSameOperands() throws {
        let source = try sourceCode(
            """
            func isSmall(_ count: Int) -> Bool {
                return count < 10
            }
            """
        )
        let visitor = RelationalBoundaryOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))

        visitor.walk(source)

        let mutations = visitor.schemataMappings.mutationSchemata.map { $0.syntaxMutation.description.trimmed }
        XCTAssertEqual(mutations, ["return count <= 10"])
    }

    func test_ignoresAnOperatorsDeclaration() {
        let visitor = RelationalBoundaryOperator.Visitor(sourceCodeInfo: sourceWithConditionalLogic)

        visitor.walk(sourceWithConditionalLogic.code)

        XCTAssertFalse(visitor.schemataMappings.codeBlocks.contains("func <= "))
        XCTAssertFalse(visitor.schemataMappings.mutationSchemata.contains { $0.position.line == 18 })
    }

    func test_ignoresConditionalConformanceConstraints_andCodeWithoutComparisons() {
        for source in [conditionalConformanceConstraints, sourceWithoutMutableCode] {
            let visitor = RelationalBoundaryOperator.Visitor(sourceCodeInfo: source)

            visitor.walk(source.code)

            XCTAssertTrue(visitor.schemataMappings.isEmpty, source.path)
        }
    }

    // Both operators mutate the same `<`, each with its own mutant: their IDs name the operator, so they don't collide.
    func test_aComparison_getsABoundaryMutant_besideItsReplacement() throws {
        let source = try sourceCode(
            """
            func isSmall(_ count: Int) -> Bool {
                return count < 10
            }
            """
        )
        let info = SourceCodeInfo(path: "/path/to/file.swift", code: source)
        let replacement = ROROperator.Visitor(sourceCodeInfo: info)
        let boundary = RelationalBoundaryOperator.Visitor(sourceCodeInfo: info)

        replacement.walk(source)
        boundary.walk(source)

        let replacementMutant = try XCTUnwrap(replacement.schemataMappings.mutationSchemata.first)
        let boundaryMutant = try XCTUnwrap(boundary.schemataMappings.mutationSchemata.first)
        XCTAssertEqual(replacementMutant.position, boundaryMutant.position)
        XCTAssertEqual(replacementMutant.snapshot.after, ">")
        XCTAssertEqual(boundaryMutant.snapshot.after, "<=")
        XCTAssertNotEqual(replacementMutant.id, boundaryMutant.id)
        XCTAssertTrue(boundaryMutant.id.contains("_RelationalBoundary_"), boundaryMutant.id)
    }
}
