@testable import muterCore
import XCTest

/// `// muter:disable` and `// muter:enable` act by where they are, once each, whichever nodes share the comment. A tag
/// beside code leaves that code off: a `disable` covers the code it follows, and an `enable` starts after it.
final class DisableTagTests: MuterTestCase {
    private func mutants(in code: String, by id: MutationOperator.Id) throws -> [MutationSchema] {
        let source = try sourceCode(code)
        let visitor = id.visitor(nil, .init(path: "/path/to/file", code: source), .empty)
        visitor.walk(source)
        return visitor.schemataMappings.mutationSchemata
    }

    private func changes(in code: String, by id: MutationOperator.Id) throws -> [String] {
        try mutants(in: code, by: id)
            .map { "\($0.position.line) \($0.snapshot.description)" }
            .sorted()
    }

    private func removedStatements(in code: String) throws -> [String] {
        try mutants(in: code, by: .removeSideEffects).map(\.snapshot.before).sorted()
    }

    // The nodes that share the comment used to take turns, so this depended on how many there were.
    func test_anEnableBesideCode_leavesThatCodeOff_whateverSharesTheComment() throws {
        for line in [
            "return true // muter:enable",
            "return g(true) // muter:enable",
            "let a = g(true) // muter:enable",
            "_ = g(true) // muter:enable",
            "g(true) // muter:enable",
        ] {
            let code = "func f() {\n    // muter:disable\n    \(line)\n    g(true)\n}"
            XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["4 changed true to false"], line)
        }
    }

    func test_anEnableBesideAMembersValue_leavesItOff() throws {
        let code = """
        struct S {
            // muter:disable
            var a = true // muter:enable
            var b = true
        }
        """
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["4 changed true to false"])
    }

    func test_anEnableBesideCode_leavesItOff_forEachKindOfOperator() throws {
        let cases: [(MutationOperator.Id, String, String)] = [
            (.ror, "return a == b // muter:enable", "6 changed == to !="),
            (.logicalOperator, "return a && b // muter:enable", "6 changed && to ||"),
            (.arithmeticOperator, "return a - b // muter:enable", "6 changed - to +"),
        ]
        for (id, line, expected) in cases {
            let symbol = line.split(separator: " ")[2]
            let code = """
            func f() {
                // muter:disable
                \(line)
            }
            func g() {
                return a \(symbol) b
            }
            """
            XCTAssertEqual(try changes(in: code, by: id), [expected], line)
        }
    }

    func test_anEnableBesideCode_startsAfterIt_withNoDisableBesideIt() throws {
        let code = """
        func f() {
            // muter:disable
            g(true)
            g(true) // muter:enable
            g(true)
        }
        """
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["5 changed true to false"])
    }

    // It used to turn on all of the list it ended, from the list's first statement.
    func test_anEnableOnTheLastStatement_leavesTheEarlierOnesOff() throws {
        let code = """
        func f() {
            // muter:disable
            g(true)
            g(true) // muter:enable
        }
        func h() {
            g(true)
        }
        """
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["7 changed true to false"])
    }

    func test_aDisableBesideCode_coversThatCode_andWhatFollows() throws {
        let code = """
        func f() {
            g(true)
            g(true) // muter:disable
            g(true)
        }
        """
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["2 changed true to false"])
    }

    // It used to turn off all of the list it ended, from the list's first statement.
    func test_aDisableOnTheLastStatement_leavesTheEarlierOnesOn() throws {
        let code = """
        func f() {
            g(true)
            g(true) // muter:disable
        }
        """
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["2 changed true to false"])

        let member = """
        struct S {
            var a = true
            var b = true // muter:disable
        }
        """
        XCTAssertEqual(try changes(in: member, by: .flipBooleanLiteral), ["2 changed true to false"])
    }

    func test_twoTagsTogether_endWithTheLast() throws {
        let turnedOn = "func f() {\n    // muter:disable\n    // muter:enable\n    g(true)\n    g(true)\n}"
        XCTAssertEqual(
            try changes(in: turnedOn, by: .flipBooleanLiteral),
            ["4 changed true to false", "5 changed true to false"]
        )

        let turnedOff = "func f() {\n    // muter:enable\n    // muter:disable\n    g(true)\n    g(true)\n}"
        XCTAssertEqual(try changes(in: turnedOff, by: .flipBooleanLiteral), [])
    }

    func test_anEnableWithNothingOff_changesNothing() throws {
        let code = "func f() {\n    g(true) // muter:enable\n    g(true)\n}"
        XCTAssertEqual(
            try changes(in: code, by: .flipBooleanLiteral),
            ["2 changed true to false", "3 changed true to false"]
        )
    }

    // RemoveSideEffects judges a block's statements before it walks into any of them.
    func test_aTagInsideAnEarlierStatement_coversTheStatementsAfterIt() throws {
        let code = """
        func f() {
            work(1)
            if a {
                // muter:disable
                work(2)
            }
            work(3)
        }
        """
        XCTAssertEqual(try removedStatements(in: code), ["work(1)"])
    }

    func test_anEnableInsideAnEarlierStatement_coversTheStatementsAfterIt() throws {
        let code = """
        func f() {
            // muter:disable
            work(1)
            if a {
                // muter:enable
                work(2)
            }
            work(3)
        }
        """
        XCTAssertEqual(try removedStatements(in: code), ["work(3)"])
    }

    // A comment's place decides, so one in a line of code that isn't its end takes effect from there.
    func test_aTagInsideAnExpression_takesEffectFromThere() throws {
        let code = "func f() {\n    g(true,\n      // muter:disable\n      true)\n}"
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["2 changed true to false"])
    }

    func test_aMentionOfATagInABlockComment_doesNothing() throws {
        let code = "func f() {\n    /* muter:disable */\n    g(true)\n}"
        XCTAssertEqual(try changes(in: code, by: .flipBooleanLiteral), ["3 changed true to false"])
    }
}
