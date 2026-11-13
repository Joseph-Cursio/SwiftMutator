import SwiftParser
import TestingExtensions
import XCTest

extension SwapTernaryOperatorTests {
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

    // At the end of a `guard` condition, a `{` followed by `else` opens the guard's body rather than
    // a trailing closure. The swap moved the then-branch's closure there, so the mutant did not
    // parse, and the reparse dropped `else { return 0 }` and `return 1`. The `!` makes the branch a
    // prefix expression rather than a call, so this pins the rule to the last token being a `}`.
    func test_parenthesizesAThenBranchThatEndsInAClosure() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ c: Bool, _ d: Bool, _ xs: [Int]) -> Int {
            guard c ? !xs.contains { $0 > 1 } : d else { return 0 }
            return 1
        }
        """)

        XCTAssertEqual(
            mutations.map(collapsingWhitespace),
            ["guard c ? d : (!xs.contains { $0 > 1 }) else { return 0 } return 1"]
        )
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // A postfix `#if` block can end the else-branch, and only a comment may follow a `#endif` on its
    // line. Swapped before the `:`, the `#endif` had the `:` on its line.
    func test_startsTheColonOnANewLineAfterAnElseBranchEndingInEndif() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ c: Bool, _ a: Int, _ b: Int) -> Int {
            return c ? a : b
                #if DEBUG
                .advanced(by: 1)
                #endif
        }
        """)

        XCTAssertEqual(mutations.map(collapsingWhitespace), ["return c ? b #if DEBUG .advanced(by: 1) #endif : a"])
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // The same with the then-branch, which the swap moves to the end, before whatever follows the
    // ternary: here a comment and then `else`. The comment stays, and the line break follows it.
    func test_endsTheLineAfterAThenBranchEndingInEndif() throws {
        let mutations = try swappedMutationTexts(of: """
        func pick(_ c: Bool, _ d: Bool, _ xs: [Int]) -> Int {
            guard c ? xs.isEmpty
                #if DEBUG
                .description.isEmpty
                #endif
                : d /* kept */ else { return 0 }
            return 1
        }
        """)

        XCTAssertEqual(
            mutations.map(collapsingWhitespace),
            ["guard c ? d : xs.isEmpty #if DEBUG .description.isEmpty #endif /* kept */ else { return 0 } return 1"]
        )
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }

    // Inside a multi-line string's interpolation, every line must be indented at least as far as the
    // closing `"""`. The line break after a `#endif` takes the `#endif`'s indentation, so the `)` or
    // `:` that it moves to a new line still is.
    func test_indentsTheLineAfterAnEndifLikeTheEndif() throws {
        let mutations = try swappedMutationTexts(of: #"""
        func pick(_ c: Bool, _ a: Int, _ b: Int) -> String {
            return """
                \(c ? a
                    #if DEBUG
                    .advanced(by: 1)
                    #endif
                    : b)
                \(c ? a : b
                    #if DEBUG
                    .advanced(by: 2)
                    #endif
                )
                """
        }
        """#)

        XCTAssertEqual(mutations.count, 2)
        for mutation in mutations {
            XCTAssertFalse(Parser.parse(source: mutation).hasError, mutation)
        }
    }
}
