@testable import muterCore
import XCTest

/// ChangeArithmeticOperator swaps `+` and `-`, `*` and `/`, turns `%` into `*`, and does the same to their assignment
/// forms. It finds its operators as RelationalOperatorReplacement does, so only in an expression.
final class ChangeArithmeticOperatorTests: MuterTestCase {
    private func mutants(of code: String) throws -> [String] {
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

    // `+` also joins strings and arrays, which `-` can't take apart, and a syntax tree has no types.
    func test_aPlusWithNoSignOfNumbers_isLeftAlone() throws {
        for code in [
            "_ = a + b",
            "_ = a + b + c",
            "_ = (a + b) + c",
            "text += a",
            "text += a + b",
            #"_ = name + "!""#,
            #"_ = "!" + name"#,
            #"_ = "\(a)" + name"#,
            "_ = list + [1]",
            #"text += "x""#,
            "list += [1]",
            "_ = g(1) + a",
            "_ = a[1] + b",
            "_ = a.first + b",
            "_ = discount + b",
            // An operator in parentheses is a sign only if it's an arithmetic one.
            #"_ = a + (b ?? "")"#,
            "_ = (a ?? []) + b",
            "_ = a + (b == c)",
            // A number in parentheses is a sign only if all of it is arithmetic.
            #"_ = "item" + (n == 1 ? "" : "s")"#,
            #"_ = "(" + (n == 1 ? "a" : "b") + ")""#,
            #"_ = (n == 1 ? "a" : "b") + s"#,
            "_ = names + (xs.count > 1 ? extras : [])",
            // `+=` takes all that follows, so what comes before a lower operator there isn't its operand.
            #"text += count == 1 ? "" : "s""#,
            #"text += items.count > 1 ? "s" : """#,
            #"text += 1 == n ? "a" : "b""#,
            "list += xs.count > 0 ? xs : []",
            "xs += 1...3",
            "xs += 1..<n",
        ] {
            XCTAssertEqual(try mutants(of: "func f() { \(code) }"), [], code)
        }
    }

    func test_aPlusBesideANumericLiteral_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = 1 + a }"), ["_ = 1 - a"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + 1.5 }"), ["_ = a - 1.5"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (1) }"), ["_ = a - (1)"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (try 1) }"), ["_ = a - (try 1)"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (await 1) }"), ["_ = a - (await 1)"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (unsafe 1) }"), ["_ = a - (unsafe 1)"])
        XCTAssertEqual(try mutants(of: "func f() { _ = lineCount! + a }"), ["_ = lineCount! - a"])
        XCTAssertEqual(try mutants(of: "func f() { _ = (x?.count)! + a }"), ["_ = (x?.count)! - a"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + -b }"), ["_ = a - -b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + !b }"), [])
        XCTAssertEqual(try mutants(of: "func f() { n += 1 }"), ["n -= 1"])
        XCTAssertEqual(try mutants(of: "func f() { t[k, default: 0] += 1 }"), ["t[k, default: 0] -= 1"])
    }

    // Each `+` of a run is judged by the whole run, whichever side the number is on.
    func test_everyPlusOfARunWithANumber_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a + b + 1 }"), ["_ = a + b - 1", "_ = a - b + 1"])
        XCTAssertEqual(try mutants(of: "func f() { _ = 1 + a + b }"), ["_ = 1 + a - b", "_ = 1 - a + b"])
        XCTAssertEqual(try mutants(of: "func f() { n += a + 1 }"), ["n += a - 1", "n -= a + 1"])
        XCTAssertEqual(try mutants(of: "func f() { count += a + b }"), ["count += a - b", "count -= a + b"])
        XCTAssertEqual(try mutants(of: "func f() { count += a > 1 ? b : c }"), ["count -= a > 1 ? b : c"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (b + 1) }"), ["_ = a + (b - 1)", "_ = a - (b + 1)"])
    }

    func test_aPlusWithACount_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = items.count + a }"), ["_ = items.count - a"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + count }"), ["_ = a - count"])
        XCTAssertEqual(try mutants(of: "func f() { lines += lineCount }"), ["lines -= lineCount"])
    }

    // Only numbers take these, so what's beside them is numbers too: `a - b + c` gets a mutant for each operator.
    func test_aPlusBesideAnotherArithmeticOperator_isMutated() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a - b + c }"), ["_ = a + b + c", "_ = a - b - c"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + b / c }"), ["_ = a + b * c", "_ = a - b / c"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a + (b - c) }"), ["_ = a + (b + c)", "_ = a - (b - c)"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a % b + c }"), ["_ = a % b - c", "_ = a * b + c"])
        XCTAssertEqual(try mutants(of: "func f() { x -= a + b }"), ["x += a + b", "x -= a - b"])
        XCTAssertEqual(try mutants(of: "func f() { x *= a + b }"), ["x *= a - b", "x /= a + b"])
        XCTAssertEqual(try mutants(of: "func f() { x /= a + b }"), ["x *= a + b", "x /= a - b"])
        XCTAssertEqual(try mutants(of: "func f() { x %= a + b }"), ["x %= a - b", "x *= a + b"])
    }

    // A string or an array is never numbers', whichever operator is beside it and whatever else the run shows.
    func test_aRunWithAStringOrArrayLiteral_isLeftAlone() throws {
        for code in [
            "_ = \"Total: \" + count",
            "_ = count + \"s\"",
            "_ = dir / name + \".swift\"",
            "_ = dir / \"name\"",
            "_ = (\"a\") + 1",
            "_ = [1] + count",
            "_ = lineCount + [1]",
            "text += \"a\" + count",
            "_ = \"a\" * 2",
        ] {
            XCTAssertEqual(try mutants(of: "func f() { \(code) }"), [], code)
        }
    }

    // A literal inside a call, or the string a member is read from, or past the end of the run, doesn't count.
    func test_aStringOrArrayLiteralOutsideTheRun_doesNotCount() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = g(\"a\") + 1 }"), ["_ = g(\"a\") - 1"])
        XCTAssertEqual(try mutants(of: "func f() { _ = \"a\".count + b }"), ["_ = \"a\".count - b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = [1][0] + 1 }"), ["_ = [1][0] - 1"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a - 1 == \"b\" }"), ["_ = a + 1 == \"b\""])
    }

    // What ends the run says nothing about the `+`: not a comparison, an assignment, a cast or a ternary.
    func test_aNumberPastTheEndOfTheRun_isNoSign() throws {
        for code in [
            "_ = a + b == 1",
            "_ = 1 == a + b",
            "_ = 1 < 2 && a + b",
            "x[1] = a + b",
            "_ = c ? 1 : a + b",
            "_ = a + b ? 1 : 2",
            "_ = a + b as Int",
            "_ = a + b is Int",
            "_ = a + b ?? 1",
            "count = a + b",
            "_ = 1 as Int + a",
            "_ = 1 is Int + a",
            "_ = count ? c : a + b",
            "_ = count & a + b",
        ] {
            XCTAssertEqual(try mutants(of: "func f() { \(code) }"), [], code)
        }
    }

    // A number inside a call or subscript is another expression's, but an operator of its own there is judged by it.
    func test_aPlusInsideAnotherExpression_isJudgedByItsOwnRun() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a + g(b + 1) }"), ["_ = a + g(b - 1)"])
    }

    // Only `+` joins: a `-` is mutated with no sign of numbers, as it is hardly ever anything else.
    func test_theOtherOperators_needNoSignOfNumbers() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = a - b }"), ["_ = a + b"])
        XCTAssertEqual(try mutants(of: "func f() { a -= b }"), ["a += b"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a * b }"), ["_ = a / b"])
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
