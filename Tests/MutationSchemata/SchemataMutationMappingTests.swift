import Foundation
@testable import muterCore
import XCTest

/// The order of a file's mutants (`SchemataMutationMapping.mutationSchemata`), which mutation testing runs them in and
/// reports them in.
final class SchemataMutationMappingTests: XCTestCase {
    private let path = "/project_mutated/Sources/Sum.swift"

    // As text, as in a switch ID, line 10 came before line 9 and line 100 before line 11, and each operator's mutants
    // came in turn.
    func test_aFilesMutants_comeByLineAndColumn_asNumbers_thenByOperator() throws {
        let mapping = try SchemataMutationMapping.make(
            filePath: path,
            (source: "let later = 1", schemata: [mutant(line: 10, column: 5), mutant(line: 9, column: 12)]),
            (source: "let earlier = 2", schemata: [
                mutant(line: 100, column: 5),
                mutant(line: 9, column: 5, .ror),
                mutant(line: 11, column: 5, .removeSideEffects),
                mutant(line: 9, column: 5, .logicalOperator),
            ])
        )

        XCTAssertEqual(mapping.mutationSchemata.map(label), [
            "9:5 ChangeLogicalConnector",
            "9:5 RelationalOperatorReplacement",
            "9:12 RelationalOperatorReplacement",
            "10:5 RelationalOperatorReplacement",
            "11:5 RemoveSideEffects",
            "100:5 RelationalOperatorReplacement",
        ])
    }

    // Their occurrences number them in this order (`MutantKey.keys`), and so does a test plan's run.
    func test_repeatsOfAPlaceAndOperator_keepTheOrderDiscoveryFoundThemIn() throws {
        let mapping = try SchemataMutationMapping.make(
            filePath: path,
            (source: "let first = 1", schemata: [
                mutant(line: 9, column: 5, after: "first"),
                mutant(line: 10, column: 5),
                mutant(line: 9, column: 5, after: "second"),
            ])
        )

        let repeats = mapping.mutationSchemata.filter { $0.position.line == 9 }
        XCTAssertEqual(repeats.map(\.snapshot.after), ["first", "second"])

        let plan = try JSONDecoder().decode(SchemataMutationMapping.self, from: JSONEncoder().encode(mapping))
        XCTAssertEqual(plan.mutationSchemata.map(\.snapshot.after), mapping.mutationSchemata.map(\.snapshot.after))
    }

    // Blocks are kept by key, whose order varies from one process to the next, so they're put in source order: eight
    // in their order by chance would be one run in 40,320.
    func test_repeatsInSeveralBlocks_comeInTheBlocksSourceOrder() throws {
        var mapping = SchemataMutationMapping(filePath: path)
        // The last block first. Each block's leading spaces put its first statement at an offset of its own.
        for number in (1 ... 8).reversed() {
            let block = try sourceCode(String(repeating: " ", count: number) + "let block\(number) = \(number)")
            try mapping.add(block.statements, mutant(line: 9, column: 5, after: "\(number)"))
        }

        XCTAssertEqual(mapping.mutationSchemata.map(\.snapshot.after), (1 ... 8).map { "\($0)" })
    }

    private func mutant(
        line: Int,
        column: Int,
        _ mutationOperatorId: MutationOperator.Id = .ror,
        after: String = "<"
    ) throws -> MutationSchema {
        try .make(
            filePath: path,
            mutationOperatorId: mutationOperatorId,
            position: MutationPosition(utf8Offset: line * 100 + column, line: line, column: column),
            snapshot: .make(before: ">", after: after, description: "changed > to \(after)")
        )
    }

    private func label(_ schema: MutationSchema) -> String {
        "\(schema.position.line):\(schema.position.column) \(schema.mutationOperatorId.rawValue)"
    }
}
