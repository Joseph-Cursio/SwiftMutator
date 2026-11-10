@testable import muterCore
import XCTest

extension ReplaceBooleanValueOperatorTests {
    // That operator replaces such a comparison with its constants, and with the swap it gives an ordering comparison
    // they stand for this pair: where `a < b` is false, its swap `a != b` is true wherever `true` is wrong too.
    func test_aComparison_isLeftToRelationalOperatorReplacement_whenThatOperatorIsOn() throws {
        for value in [
            "a == b", "a != b", "a < b", "a <= b", "a > b", "a >= b", "a + 1 < b", "(a < b)", "a.count == b.count",
        ] {
            let code = "func f() { let x = \(value) }"
            XCTAssertEqual(try values(in: code, leavingComparisonsAlone: true), [], value)
            XCTAssertEqual(try values(in: code), [value], value)
        }
        for code in [
            "func f() -> Bool { return a < b }",
            "func f() -> Bool { a == b }",
            "func f() throws -> Bool { try load() >= b }",
            "func f() async -> Bool { await load() != b }",
            "func f() { let x: Bool = a <= b }",
            "func f() { let x: Bool? = a > b }",
        ] {
            XCTAssertEqual(try values(in: code, leavingComparisonsAlone: true), [], code)
        }
    }

    // That operator leaves out all of a comparison's mutants when a directive leaves out one, here its swap, placed
    // where the operator's leading trivia starts, after `x)`, and then nothing stands for this pair, whose places,
    // where the value starts and ends, the directive doesn't reach.
    func test_aComparisonWhoseMutantsADirectiveLeavesOut_staysThisOperators() throws {
        let code = """
        func f() -> Bool {
            return load(
                // muter:disable-next-line
                x)
                < b
        }
        """
        XCTAssertEqual(
            try values(in: code, leavingComparisonsAlone: true),
            ["load( // muter:disable-next-line x) < b"]
        )
    }

    // `&&`, `||`, `!` and an identity check are this operator's still, and so is a comparison under any of them.
    func test_everythingElse_staysThisOperators_besideRelationalOperatorReplacement() throws {
        for value in [
            "a === b", "a !== b", "a && b", "a < b && c", "a == b || c", "!(a < b)", "!visible", "a < b ? c : d",
        ] {
            let code = "func f() -> Bool { \(value) }"
            XCTAssertEqual(try values(in: code, leavingComparisonsAlone: true), [value], value)
        }
        XCTAssertEqual(
            try values(in: "func f() -> Bool { items.isEmpty }", leavingComparisonsAlone: true),
            ["items.isEmpty"]
        )
        // An operator the standard table doesn't hold isn't known to be a comparison.
        XCTAssertEqual(
            try values(in: "func f() -> Bool { a <> b == c }", leavingComparisonsAlone: true),
            ["a <> b == c"]
        )
    }
}
