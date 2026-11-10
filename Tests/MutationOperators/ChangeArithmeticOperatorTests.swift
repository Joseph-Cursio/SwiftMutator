@testable import muterCore
import XCTest

/// ChangeArithmeticOperator swaps `+` and `-`, `*` and `/`, turns `%` into `*`, and does the same to their assignment
/// forms. It finds its operators as RelationalOperatorReplacement does, so only in an expression.
final class ChangeArithmeticOperatorTests: MuterTestCase {
    func mutants(of code: String) throws -> [String] {
        let source = try sourceCode(code)
        let visitor = ChangeArithmeticOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)
        return visitor.schemataMappings.mutationSchemata
            .map(\.syntaxMutation.description.trimmed)
            .sorted()
    }

    func test_eachOperator_becomesItsChange() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a + 2 }"), ["_ = a - 2"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a - b }"), ["_ = a + b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * b }"), ["_ = a / b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a / b }"), ["_ = a * b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a % b }"), ["_ = a * b"])
    }

    func test_eachAssignmentForm_becomesItsChange() throws {
        XCTAssertEqual(try mutants(of: "func f() { a += 2 }"), ["a -= 2"])
        XCTAssertEqual(try mutants(of: "func f() { a -= b }"), ["a += b"])
        XCTAssertEqual(try mutants(of: "func f() { a *= b }"), ["a /= b"])
        XCTAssertEqual(try mutants(of: "func f() { a /= b }"), ["a *= b"])
        XCTAssertEqual(try mutants(of: "func f() { a %= b }"), ["a *= b"])
    }

    func test_theMutantsSnapshot_namesTheOperators() throws {
        let source = try sourceCode("func f() { _ = a % b }")
        let visitor = ChangeArithmeticOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)

        XCTAssertEqual(
            visitor.schemataMappings.mutationSchemata.map(\.snapshot),
            [.init(before: "%", after: "*", description: "changed % to *")]
        )
        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.mutationOperatorId), [.arithmeticOperator])
    }

    // Each operator of a chain gets a mutant of its own, with the others unchanged.
    func test_eachOperatorOfAChain_getsAMutant() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a + b * c }"), ["_ = a + b / c", "_ = a - b * c"])
    }

    // An operator that isn't in an expression has nothing for the operator to change.
    func test_ignoresWhatIsNotAnExpressionsOperator() throws {
        XCTAssertEqual(try mutants(of: "func + (a: T, b: T) -> T { a }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = xs.reduce(0, +) }"), [])
        XCTAssertEqual(try mutants(of: "@available(iOS 13, *) func f() {}"), [])
        XCTAssertEqual(try mutants(of: "func f() { if #available(iOS 13, *) {} }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = -a; _ = !b; _ = a++ }"), [])
    }

    // No test can tell `x + 0` from `x - 0`, nor `x * 1` from `x / 1`.
    func test_anOperandThatMakesTheSwapChangeNothing_isLeftAlone() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a + 0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a - 0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + 0.0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a / 1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 1.0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a += 0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a -= 0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a *= 1.0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a /= 1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * -1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a / -1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a *= -1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * (1) }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (0) }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + 0b0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 0o1 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 0x1 }"), [])
    }

    // An assignment takes all that follows, so its literal is only part of what it takes.
    func test_aLiteralThatIsOnlyPartOfAnAssignmentsOperand_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { a += 0 + b }"), ["a += 0 - b", "a -= 0 + b"])
        XCTAssertEqual(try mutants(of: "func f() { a *= 1 + b }"), ["a *= 1 - b", "a /= 1 + b"])
    }

    // On the left, the same numbers do change the result: `0 - x` isn't `0 + x`.
    func test_theSameLiteralOnTheLeft_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = 0 + a }"), ["_ = 0 - a"])
        XCTAssertEqual(try mutants(of: "func f() { _ = 1 * a }"), ["_ = 1 / a"])
    }

    // `x / 0` doesn't compile.
    func test_multiplyingByALiteralZero_isLeftAlone() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a *= 0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * (0) }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 0b0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * -0 }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * (-0) }"), [])
        XCTAssertEqual(try mutants(of: "func f() { a *= -0 }"), [])
    }

    // A float divides by a literal zero, whatever it gives.
    func test_multiplyingByAFloatZero_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a * 0.0 }"), ["_ = a / 0.0"])
        XCTAssertEqual(try mutants(of: "func f() { a *= 0.0 }"), ["a /= 0.0"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * -0.0 }"), ["_ = a / -0.0"])
    }

    // Placed at the operator, not at the end of the line before, and with no comment beside it in its snapshot.
    func test_anOperatorThatStartsALine_isPlacedAtItself() throws {
        let source = try sourceCode(
            """
            func f() {
                _ = a // why
                    - b
            }
            """
        )
        let visitor = ChangeArithmeticOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)

        let mutant = try XCTUnwrap(visitor.schemataMappings.mutationSchemata.first)
        XCTAssertEqual(mutant.position.line, 3)
        XCTAssertEqual(mutant.position.column, 9)
        XCTAssertEqual(mutant.snapshot, .init(before: "-", after: "+", description: "changed - to +"))
    }

    // `a //* why */ b` would be a comment to the end of the line.
    func test_aSlashThatWouldStartAComment_isLeftAlone() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a */* why */ b }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a */** why */ b }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a *// why\n b }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a */// why\n b }"), [])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * /* why */ b }"), ["_ = a / /* why */ b"])
    }

    // Only `*` becomes a `/` beside the comment.
    func test_theOtherOperatorsTouchingAComment_areMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a %/* why */ b }"), ["_ = a */* why */ b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a -/* why */ b }"), ["_ = a +/* why */ b"])
        XCTAssertEqual(try mutants(of: "func f() { a *=/* why */ b }"), ["a /=/* why */ b"])
    }

    func test_aCompilerDirectivesCondition_isLeftAlone_andItsCodeIsNot() throws {
        XCTAssertEqual(
            try mutants(of: """
            func f() {
                #if VALUE + 1
                _ = a + 2
                #endif
            }
            """).map(collapsingWhitespace),
            ["_ = a - 2"]
        )
    }

    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try mutants(of: """
        func f() {
            // muter:disable
            _ = a + 2
            // muter:enable
            _ = c + 2
        }
        """).map(collapsingWhitespace), ["// muter:disable _ = a + 2 // muter:enable _ = c - 2"])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let source = try sourceCode("""
            func f() {
                if a {
                    _ = b + 2
                }
                _ = c + 2
            }
            """)
        let visitor = ChangeArithmeticOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )
        visitor.walk(source)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5])
    }

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
