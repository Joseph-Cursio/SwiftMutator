@testable import muterCore
import XCTest

/// FlipBooleanLiteral turns `true` into `false` and `false` into `true`, but in a whole condition or a pattern.
final class FlipBooleanLiteralOperatorTests: MuterTestCase {
    private func mutants(of code: String) throws -> [String] {
        let source = try sourceCode(code)
        let visitor = FlipBooleanLiteralOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)
        return visitor.schemataMappings.mutationSchemata
            .map(\.syntaxMutation.description.trimmed)
            .sorted()
    }

    func test_eachLiteral_becomesTheOther() throws {
        XCTAssertEqual(try mutants(of: "func f() -> Bool { return true }"), ["return false"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { return false }"), ["return true"])
    }

    func test_theMutant_isPlacedAtTheLiteral_andItsSnapshotNamesIt() throws {
        let source = try sourceCode(
            """
            func f() -> Bool {
                // why
                return g(x:
                    true)
            }
            """
        )
        let visitor = FlipBooleanLiteralOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)

        let mutant = try XCTUnwrap(visitor.schemataMappings.mutationSchemata.first)
        XCTAssertEqual(mutant.mutationOperatorId, .flipBooleanLiteral)
        XCTAssertEqual(mutant.position.line, 4)
        XCTAssertEqual(mutant.position.column, 9)
        XCTAssertEqual(mutant.snapshot, .init(before: "true", after: "false", description: "changed true to false"))
    }

    func test_anArgument_anAssignment_aReturn_andAnOperand_areEachFlipped() throws {
        XCTAssertEqual(try mutants(of: "func f() { g(x: true) }"), ["g(x: false)"])
        XCTAssertEqual(try mutants(of: "func f() { a = false }"), ["a = true"])
        XCTAssertEqual(try mutants(of: "func f() { _ = a ?? true }"), ["_ = a ?? false"])
        XCTAssertEqual(try mutants(of: "func f() { _ = true ? a : b }"), ["_ = false ? a : b"])
        XCTAssertEqual(try mutants(of: "func f() { if a == true {} }"), ["if a == false {}"])
        XCTAssertEqual(try mutants(of: "func f() { if g(true) {} }"), ["if g(false) {}"])
    }

    func test_eachLiteralOfAList_getsAMutant() throws {
        XCTAssertEqual(try mutants(of: "func f() { _ = [true, false] }"), ["_ = [false, false]", "_ = [true, true]"])
    }

    // To the compiler `while true` never ends and `if true` is always taken, which lets a function end without a
    // `return`. Flipped, it doesn't compile.
    func test_aWholeCondition_isLeftAlone() throws {
        for code in [
            "if true {}",
            "if false {} else {}",
            "if (true) {}",
            "if ((true)) {}",
            "guard true else { return }",
            "while true {}",
            "while (false) {}",
            "repeat {} while true",
            "repeat {} while (true)",
            "if a, true {}",
            "_ = if true { 1 } else { 2 }",
        ] {
            XCTAssertEqual(try mutants(of: "func f() { \(code) }"), [], code)
        }
    }

    // Flipping `case true:` leaves a `switch` that isn't exhaustive.
    func test_aPattern_isLeftAlone() throws {
        for code in [
            "switch a { case true: break; case false: break }",
            "switch (a, b) { case (true, _): break; case (false, _): break }",
            "switch a { case .on(true): break; case .on(false): break }",
            "if case true = a {}",
            "for case true in a {}",
        ] {
            XCTAssertEqual(try mutants(of: "func f() { \(code) }"), [], code)
        }
    }

    // What a `case` runs, a `where` clause and a `switch`'s subject are ordinary expressions.
    func test_whatIsAroundAPattern_isFlipped() throws {
        XCTAssertEqual(
            try mutants(of: "func f() { switch a { case true: g(true); case false: break } }")
                .map(collapsingWhitespace),
            ["g(false);"]
        )
        XCTAssertEqual(
            try mutants(of: "func f() { switch a { case 1 where true: break; default: break } }"),
            ["switch a { case 1 where false: break; default: break }"]
        )
        XCTAssertEqual(
            try mutants(of: "func f() { switch true { case a: break; default: break } }"),
            ["switch false { case a: break; default: break }"]
        )
        XCTAssertEqual(
            try mutants(of: "func f() { switch a { case g({ true }): break; default: break } }")
                .map(collapsingWhitespace),
            ["false"]
        )
    }

    func test_aCompilerDirectivesCondition_isLeftAlone_andItsCodeIsNot() throws {
        XCTAssertEqual(
            try mutants(of: """
            func f() {
                #if true
                g(true)
                #endif
            }
            """).map(collapsingWhitespace),
            ["g(false)"]
        )
    }

    // A `#if`'s condition at any depth, whatever wraps it.
    func test_aCompilerDirectivesCondition_isLeftAlone_whateverWrapsIt() throws {
        for condition in ["true", "(true)", "!false", "true && A", "A || (B && false)"] {
            XCTAssertEqual(try mutants(of: "#if \(condition)\nlet a = 1\n#endif"), [], condition)
        }
    }

    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try mutants(of: """
        func f() {
            // muter:disable
            g(true)
            // muter:enable
            g(false)
        }
        """).map(collapsingWhitespace), ["// muter:disable g(true) // muter:enable g(true)"])
    }

    // The tag can sit on the literal itself, so it has to be read before the literal is.
    func test_aDisableTagOnTheLiteral_isRead() throws {
        XCTAssertEqual(try mutants(of: """
        func f() {
            g(x:
                // muter:disable
                true)
        }
        """), [])
    }

    func test_aPropertysValue_andADefaultArgument_areSwitchedInTheValue() throws {
        let source = try sourceCode(
            """
            struct S {
                var a = true
                func f(b: Bool = false) {}
            }
            """
        )
        let visitor = FlipBooleanLiteralOperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))
        visitor.walk(source)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 2)
        XCTAssertEqual(visitor.droppedMutants, [])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let source = try sourceCode("""
            func f() {
                if a {
                    g(true)
                }
                g(false)
            }
            """)
        let visitor = FlipBooleanLiteralOperator.Visitor(
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
