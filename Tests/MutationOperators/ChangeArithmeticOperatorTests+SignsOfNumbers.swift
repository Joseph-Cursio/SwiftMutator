import XCTest

extension ChangeArithmeticOperatorTests {
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
}
