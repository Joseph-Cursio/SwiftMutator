@testable import muterCore
import TestingExtensions
import XCTest

/// `--changed-lines`: which of a changed file's mutants discovery keeps.
final class DiscoverMutationPointsChangedLinesTests: MuterTestCase {
    let state = MutationTestState()

    // Line 2 holds `<`, which RelationalOperatorReplacement and RelationalBoundary each mutate, and whose right-hand
    // operand is on line 3, where the first's constant is placed, as the comparison ends there; lines 8 and 9
    // statements RemoveSideEffects removes; line 13 `==`, which RelationalOperatorReplacement replaces with each
    // constant, and ReplaceBooleanValue leaves to it, as NegateConditional does the condition on line 2.
    let source = """
    func check(index: Int, items: [Int]) -> Bool {
        guard index <
            items.count - 1 else { return false }
        return true
    }

    func save(index: Int) {
        _ = record(index)
        _ = record(index + 1)
    }

    func other(a: Int) -> Bool {
        return a == 3
    }

    """

    override func setUp() {
        super.setUp()
        state.mutationOperatorList = .allOperators
        prepareCode.sourceCodeToReturn = {
            muterCore.sourceCode(fromFileAt: $0).map { (source: $0, changes: .null) }
        }
    }

    // The operator alone is on line 2, but what it compares changed.
    func test_anOperatorWhoseOperandChanged_isKept() async throws {
        let kept = try await mutants(changing: [LineRange(first: 3, last: 3)])

        XCTAssertEqual(
            kept.map(\.operatorAndLine),
            [
                "RelationalBoundary:2",
                "RelationalOperatorReplacement:2",
                "ChangeArithmeticOperator:3",
                "RelationalOperatorReplacement:3",
                "FlipBooleanLiteral:3",
            ]
        )
    }

    func test_aChangedStatement_isKept_andTheUnchangedOnesAreNot() async throws {
        let kept = try await mutants(changing: [LineRange(first: 8, last: 8)])

        XCTAssertEqual(kept.map(\.operatorAndLine), ["RemoveSideEffects:8"])
    }

    // Lines removed between 2 and 3, from the middle of the condition.
    func test_anExpressionLinesWereRemovedFrom_isKept() async throws {
        let kept = try await mutants(removingAfter: [2])

        XCTAssertEqual(
            kept.map(\.operatorAndLine),
            [
                "RelationalBoundary:2",
                "RelationalOperatorReplacement:2",
                "ChangeArithmeticOperator:3",
                "RelationalOperatorReplacement:3",
            ]
        )
    }

    func test_withoutChangedLines_everyMutantOfAChangedFileIsKept() async throws {
        let kept = try await mutants(changing: [LineRange(first: 8, last: 8)], changedLines: false)

        XCTAssertEqual(kept.count, 11)
    }

    func test_noMutantOnAChangedLine_leavesNothingToMutate() async throws {
        let selection = try prepare(changing: [LineRange(first: 6, last: 6)])

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noMutantOnChangedLines, selection: selection)
            )
        }
    }

    // Declarations only: no operator mutates them, which is nothing to mutate rather than a failure.
    func test_aChangedFileWithoutMutants_leavesNothingToMutate() async throws {
        let selection = try prepare(changing: nil, source: "struct Model {\n    let name: String\n}\n")

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertEqual(
                error as? NothingToMutate,
                NothingToMutate(reason: .noMutantInChangedFiles(count: 1), selection: selection)
            )
        }
    }
}

private extension MutationSchema {
    var operatorAndLine: String {
        "\(mutationOperatorId.rawValue):\(position.line)"
    }
}
