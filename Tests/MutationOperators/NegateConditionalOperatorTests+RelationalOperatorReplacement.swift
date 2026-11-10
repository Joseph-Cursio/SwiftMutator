import XCTest

extension NegateConditionalOperatorTests {
    // That operator's constant gives the same wrong result wherever the negation does: where `a < b` is true, `false`
    // and `!(a < b)` both are false.
    func test_aLoneComparison_isLeftToRelationalOperatorReplacement_whenThatOperatorIsOn() {
        let code = inAFunction("""
        if a == b { work() }
        guard a != b else { return }
        while (a < b) { work() }
        if a <= b { work() }
        if a > b { work() }
        guard a >= b else { return }
        if !(a != b) { work() }
        if try a == b { work() }
        if try (a < b) { work() }
        if await (a == b) { work() }
        """)

        XCTAssertEqual(negations(in: code, leavingComparisonsAlone: true), [])
        XCTAssertEqual(negations(in: code).count, 10)
    }

    // The tree isn't folded, so these are sequences of five or more, but a comparison is still what's worked out last.
    func test_aComparisonWithOperatorsInItsOperands_isLeftAlone_too() {
        let code = inAFunction("""
        if n % 2 == 0 { work() }
        if n & 1 != 0 { work() }
        if n ?? 0 == 1 { work() }
        if a as? Int == 1 { work() }
        if a == b as Int { work() }
        if (n + 1) * 2 == n { work() }
        while s.count - 1 != i { work() }
        guard i + 1 == s.count else { return }
        if try i + 1 == s.count { work() }
        if n + 1 < limit { work() }
        while i * 2 >= s.count { work() }
        """)

        XCTAssertEqual(negations(in: code, leavingComparisonsAlone: true), [])
    }

    // Something else is worked out last, or an operator the standard table doesn't hold could be anything, and that
    // operator gives no constant there.
    func test_aLowerOperatorOverAComparison_isNegated() {
        let code = inAFunction("""
        if a == b || c == d { work() }
        if a < b && c { work() }
        if a == b ? c : d { work() }
        if a <> b == c { work() }
        if a <> b < c { work() }
        """)

        XCTAssertEqual(negations(in: code, leavingComparisonsAlone: true), [
            "!(a == b || c == d)",
            "!(a < b && c)",
            "!(a == b ? c : d)",
            "!(a <> b == c)",
            "!(a <> b < c)",
        ])
    }

    // That operator gives no constant to a comparison that holds a closure's only use of its `$0`, as the closure
    // would then take no argument.
    func test_aComparisonThatGetsNoConstant_isNegated() {
        let code = inAFunction("""
        items.forEach { if $0 > 1 { work() } }
        items.forEach { x in if x > 1 { work() } }
        """)

        XCTAssertEqual(negations(in: code, leavingComparisonsAlone: true), ["!($0 > 1)"])
    }

    // That operator leaves out all of a comparison's mutants when a directive leaves out one, and then nothing stands
    // for the negation, whose own place, where the condition starts, the directive doesn't reach.
    func test_aComparisonWhoseMutantsADirectiveLeavesOut_isNegated() {
        let code = inAFunction("""
        if a ==
            // muter:disable-next-line
            b { work() }
        while a
            // muter:disable-next-line
            < b { work() }
        // muter:disable-next-line
        if a == b { work() }
        """)

        XCTAssertEqual(negations(in: code, leavingComparisonsAlone: true), [
            "!(a == // muter:disable-next-line b)",
            "!(a // muter:disable-next-line < b)",
        ])
        XCTAssertEqual(negations(in: code).count, 2)
    }

    // That operator leaves `===` and `!==` alone.
    func test_everythingElse_isNegated_besideRelationalOperatorReplacement() {
        let code = inAFunction("""
        if a === b { work() }
        if a !== b { work() }
        if a == b && c { work() }
        if a == b, c { work() }
        if a { work() }
        """)

        XCTAssertEqual(negations(in: code, leavingComparisonsAlone: true), [
            "!(a === b)",
            "!(a !== b)",
            "!(a == b && c)",
            "!(c)",
            "!(a)",
        ])
    }
}
