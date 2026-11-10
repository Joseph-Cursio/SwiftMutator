@testable import muterCore
import SwiftParser
import XCTest

extension MutantDiffTests {
    // The snapshot gives a node that spans lines on one line, which no line of the file holds.
    func test_aMultiLineNode_fallsBackToTheSnapshot() throws {
        let source = """
        func pick(_ flag: Bool) -> Int {
            return flag
                ? 1
                : 2
        }

        """
        let schema = try XCTUnwrap(schemata(MutationOperator.Id.swapTernary.visitor, in: source).first)

        XCTAssertNil(MutantDiff.lines(
            original: source,
            snapshot: schema.snapshot,
            mutationOperatorId: schema.mutationOperatorId,
            line: schema.position.line,
            column: schema.position.column
        ))
        XCTAssertEqual(MutantDiff.fallback(snapshot: schema.snapshot, mutationOperatorId: .swapTernary), [
            "- flag ? 1 : 2",
            "+ flag ? 2 :  1",
        ])
    }

    // A file that no longer holds the mutant's code where it was found, as one changed since a test plan was made.
    func test_textThatDoesntMatch_fallsBack() {
        let snapshot = MutationOperator.Snapshot(before: "flag ? 1 : 2", after: "flag ? 2 : 1", description: "")

        XCTAssertNil(MutantDiff.lines(
            original: "func pick() -> Int {\n    return 3\n}\n",
            snapshot: snapshot,
            mutationOperatorId: .swapTernary,
            line: 2,
            column: 17
        ))
        XCTAssertNil(MutantDiff.lines(
            original: "let one = 1\n",
            snapshot: snapshot,
            mutationOperatorId: .swapTernary,
            line: 7,
            column: 1
        ))
    }

    // Away from the mutant's column, a line that holds the change twice can't say which one is the mutant's.
    func test_aLineThatHoldsTheChangeTwice_awayFromTheColumn_fallsBack() {
        let snapshot = MutationOperator.Snapshot(before: "==", after: "!=", description: "changed == to !=")

        XCTAssertNil(MutantDiff.lines(
            original: "let both = a == 1 && b == 2\n",
            snapshot: snapshot,
            mutationOperatorId: .ror,
            line: 1,
            column: 40
        ))
        XCTAssertEqual(
            MutantDiff.lines(
                original: "let both = a == 1 && b == 2\n",
                snapshot: snapshot,
                mutationOperatorId: .ror,
                line: 1,
                column: 24
            ),
            ["-1: let both = a == 1 && b == 2", "+1: let both = a == 1 && b != 2"]
        )
    }
}
