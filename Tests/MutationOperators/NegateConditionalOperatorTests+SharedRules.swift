@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

extension NegateConditionalOperatorTests {
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
