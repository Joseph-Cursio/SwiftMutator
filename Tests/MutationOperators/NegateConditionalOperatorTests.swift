@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

/// NegateConditional wraps each expression condition of `if`, `guard` and `while` in `!( )`.
final class NegateConditionalOperatorTests: MuterTestCase {
    private func visitor(
        walking code: String,
        leavingComparisonsAlone: Bool = false,
        coverage: FileCoverage = .empty
    ) -> NegateConditionalOperator.Visitor {
        let source = Parser.parse(source: code)
        let visitor = NegateConditionalOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.leavesComparisonsAlone = leavingComparisonsAlone
        visitor.walk(source)
        return visitor
    }

    /// What each mutant's condition becomes, in the order of the file.
    private func negations(in code: String, leavingComparisonsAlone: Bool = false) -> [String] {
        visitor(walking: code, leavingComparisonsAlone: leavingComparisonsAlone)
            .schemataMappings.mutationSchemata
            .sorted { $0.position.utf8Offset < $1.position.utf8Offset }
            .map(\.snapshot.after)
    }

    private func inAFunction(_ statements: String) -> String {
        "func f() {\n\(statements)\n}\n"
    }

    func test_eachKindOfStatement_getsItsConditionNegated() {
        let code = inAFunction("""
        if isValid && !isEmpty { work() }
        guard ready else { return }
        while hasMore() { work() }
        """)

        XCTAssertEqual(negations(in: code), ["!(isValid && !isEmpty)", "!(ready)", "!(hasMore())"])
    }

    func test_theSnapshot_saysWhatChanged() throws {
        let schema = try XCTUnwrap(
            visitor(walking: inAFunction("if a && b { work() }")).schemataMappings.mutationSchemata.first
        )

        XCTAssertEqual(schema.mutationOperatorId, .negateConditional)
        XCTAssertEqual(schema.snapshot.before, "a && b")
        XCTAssertEqual(schema.snapshot.after, "!(a && b)")
        XCTAssertEqual(schema.snapshot.description, "negated the condition")
    }

    func test_eachConditionOfAList_getsAMutantOfItsOwn() {
        let code = inAFunction("if a, b { work() }")

        let schemata = visitor(walking: code).schemataMappings.mutationSchemata
            .sorted { $0.position.utf8Offset < $1.position.utf8Offset }

        XCTAssertEqual(schemata.map(\.snapshot.after), ["!(a)", "!(b)"])
        XCTAssertEqual(schemata.map { $0.syntaxMutation.description.trimmed }, [
            "if !(a), b { work() }",
            "if a, !(b) { work() }",
        ])
    }

    func test_conditionsThatArentExpressions_areLeftAlone_andTheOnesBesideThemArent() {
        let code = inAFunction("""
        if let value = optional { work(value) }
        if case .some = optional { work() }
        if #available(macOS 14, *) { work() }
        guard let value = optional else { return }
        while let next = iterator.next() { work(next) }
        if let value = optional, value.isReady, #available(macOS 14, *) { work() }
        """)

        XCTAssertEqual(negations(in: code), ["!(value.isReady)"])
    }

    // `repeat` and a ternary have conditions, but not of the kind this operator is for.
    func test_otherConditions_areLeftAlone() {
        let code = inAFunction("""
        repeat { work() } while hasMore()
        let value = a ? 1 : 2
        switch value { case 1 where a: work(); default: break }
        """)

        XCTAssertEqual(negations(in: code), [])
    }

    // To the compiler `while true` never ends, so a function can end without a `return` after it. Negated, it can, and
    // the function no longer compiles.
    func test_aLiteral_isLeftAlone() {
        let code = inAFunction("""
        while true { work() }
        if false { work() }
        guard (true) else { return }
        if !true { work() }
        while try (true) { work() }
        if await (true) { work() }
        """)

        XCTAssertEqual(negations(in: code), [])
    }

    func test_aNestedCondition_getsItsOwnMutant() {
        let code = inAFunction("""
        if outer {
            if inner { work() }
        }
        if items.contains(where: { item in
            if item.isSpecial { return true }
            return false
        }) { work() }
        """)

        XCTAssertEqual(Set(negations(in: code)), [
            "!(outer)",
            "!(inner)",
            "!(item.isSpecial)",
            "!(items.contains(where: { item in if item.isSpecial { return true } return false }))",
        ])
    }

    // MARK: - Trivia

    // A `//` comment after the condition must not swallow the `)`.
    func test_aCommentAfterTheCondition_staysOutsideTheParentheses() throws {
        let code = inAFunction("""
        if ready // why
        {
            work()
        }
        """)

        let schema = try XCTUnwrap(visitor(walking: code).schemataMappings.mutationSchemata.first)

        XCTAssertTrue(schema.syntaxMutation.description.contains("if !(ready) // why\n"))
        XCTAssertEqual(schema.snapshot.before, "ready")
        XCTAssertEqual(schema.snapshot.after, "!(ready)")
    }

    func test_aCommentInsideTheCondition_staysInside() throws {
        let code = inAFunction("""
        if ready && // why
            done {
            work()
        }
        """)

        let schema = try XCTUnwrap(visitor(walking: code).schemataMappings.mutationSchemata.first)

        XCTAssertTrue(schema.syntaxMutation.description.contains("if !(ready && // why\n    done) {"))
    }

    func test_aConditionOnItsOwnLine_keepsItsIndentation_andIsPlacedOnThatLine() throws {
        let code = "func f() {\n    if a,\n       b {\n        work()\n    }\n}\n"

        let second = try XCTUnwrap(
            visitor(walking: code).schemataMappings.mutationSchemata.first { $0.snapshot.before == "b" }
        )

        XCTAssertTrue(second.syntaxMutation.description.contains("if a,\n       !(b) {"))
        XCTAssertEqual(second.position.line, 3)
        XCTAssertEqual(second.position.column, 8)
        XCTAssertEqual(second.lines, 3...3)
    }

    func test_aConditionOverSeveralLines_isOnAllOfThem() throws {
        let code = "func f() {\n    if a &&\n        b {\n        work()\n    }\n}\n"

        let schema = try XCTUnwrap(visitor(walking: code).schemataMappings.mutationSchemata.first)

        XCTAssertEqual(schema.position.line, 2)
        XCTAssertEqual(schema.lines, 2...3)
    }

    // A CRLF is two newlines to `.newlines`, which must not leave two spaces in what the reports show.
    func test_aConditionOverSeveralLinesOfACRLFFile_isShownOnOneLine() throws {
        let code = "func f() {\r\n    if a &&\r\n        b { work() }\r\n}\r\n"

        let schema = try XCTUnwrap(visitor(walking: code).schemataMappings.mutationSchemata.first)

        XCTAssertEqual(schema.snapshot.before, "a && b")
        XCTAssertEqual(schema.snapshot.after, "!(a && b)")
    }

    // `if!(a)` doesn't parse, as a `!` touching what's on both sides of it reads as an infix operator.
    func test_aConditionTouchingItsKeyword_getsASpace() throws {
        for (statement, mutation) in [
            ("if(a) { work() }", "if !((a)) { work() }"),
            ("while(a) { work() }", "while !((a)) { work() }"),
            ("guard(a) else { return }", "guard !((a)) else { return }"),
        ] {
            let schema = try XCTUnwrap(visitor(walking: inAFunction(statement)).schemataMappings.mutationSchemata.first)
            XCTAssertEqual(schema.syntaxMutation.description.trimmed, mutation)
            XCTAssertFalse(Parser.parse(source: inAFunction(mutation)).hasError, statement)
        }
    }

    func test_aConditionTouchingItsComma_getsASpace() throws {
        let schemata = visitor(walking: inAFunction("if a,b { work() }")).schemataMappings.mutationSchemata
        let negated = try XCTUnwrap(schemata.first { $0.snapshot.before == "b" })

        XCTAssertEqual(negated.syntaxMutation.description.trimmed, "if a, !(b) { work() }")
    }

    // The `)` would have to follow `#endif` on its line, which nothing can.
    func test_aConditionEndingInACompilerDirective_isLeftAlone() {
        let code = inAFunction("""
        if value
            #if DEBUG
            .isReady
            #endif
        { work() }
        """)

        XCTAssertEqual(negations(in: code), [])
    }

    func test_aConditionHoldingACompilerDirective_isNegated_asTheParenthesisFollowsWhatsAfterIt() throws {
        let code = inAFunction("""
        if value
            #if DEBUG
            .debugValue
            #endif
            .isReady { work() }
        """)

        let schema = try XCTUnwrap(visitor(walking: code).schemataMappings.mutationSchemata.first)

        XCTAssertTrue(schema.syntaxMutation.description.contains(".isReady) { work() }"))
    }

    // It can only be a condition itself, though it parses as an expression. Other macros can be negated.
    func test_hasSymbol_isLeftAlone_andOtherMacrosArent() {
        let code = inAFunction("""
        if #_hasSymbol(work) { work() }
        guard #_hasSymbol(work) else { return }
        if #isReady { work() }
        """)

        XCTAssertEqual(negations(in: code), ["!(#isReady)"])
    }

    func test_aConditionInsideACompilerDirectivesClause_isNegated() {
        let code = inAFunction("""
        #if DEBUG
        if ready { work() }
        #endif
        """)

        XCTAssertEqual(negations(in: code), ["!(ready)"])
    }

    func test_tryAndAwait_stayInsideTheParentheses() {
        let code = """
        func f() async throws {
            if try check() { work() }
            if await check() { work() }
        }
        """

        XCTAssertEqual(negations(in: code), ["!(try check())", "!(await check())"])
    }

    // MARK: - RelationalOperatorReplacement's mutants

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

    // MARK: - What every operator does

    func test_disabledCode_isLeftAlone() {
        let code = inAFunction("""
        // muter:disable
        if a { work() }
        // muter:enable
        if b { work() }
        """)

        XCTAssertEqual(negations(in: code), ["!(b)"])
    }

    // A comment on a condition's own line is for that condition, whichever place in the list it's in.
    func test_aDisableCommentBesideACondition_coversIt() {
        let before = "func f() {\n    if a,\n       // muter:disable\n       b { work() }\n}\n"
        XCTAssertEqual(negations(in: before), ["!(a)"])

        let after = "func f() {\n    if a, // muter:disable\n       b { work() }\n}\n"
        XCTAssertEqual(negations(in: after), [])
    }

    func test_codeTheTestsNeverRan_isLeftAlone() {
        let code = """
        func ran() {
            if a { work() }
        }
        func never() {
            if b { work() }
        }
        """

        let mutants = visitor(
            walking: code,
            coverage: .llvmCov([[[1, 12, 3, 2, 1]], [[4, 14, 6, 2, 0]]])
        ).schemataMappings.mutationSchemata

        XCTAssertEqual(mutants.map(\.snapshot.after), ["!(a)"])
    }

    // A property's initializer has no statement list of its own, so its mutant's switch goes around the value.
    func test_anIfExpressionInAStoredProperty_isNegated() {
        let code = """
        struct S {
            let value = if flag { 1 } else { 2 }
        }
        """

        XCTAssertEqual(negations(in: code), ["!(flag)"])
    }

    func test_anIfExpressionInAStatement_isNegated() {
        let code = inAFunction("let value = if flag { 1 } else { 2 }")

        XCTAssertEqual(negations(in: code), ["!(flag)"])
    }
}
