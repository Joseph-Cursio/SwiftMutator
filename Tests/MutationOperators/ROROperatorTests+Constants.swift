@testable import muterCore
import TestingExtensions
import XCTest

extension ROROperatorTests {
    // The tree isn't folded, so the operators' precedence says how much of a sequence is the comparison.
    func test_theConstant_replacesTheComparison_asTheStandardTableFoldsIt() throws {
        for (value, constant) in [
            ("a + 1 < b", "false"),
            ("a * 2 + 1 < b - c", "false"),
            ("n ?? 0 < 1", "false"),
            ("x < y && z", "false && z"),
            ("z || x < y", "z || false"),
            ("x < y ? c : d", "false ? c : d"),
            ("a < b && c < d", "false && c < d"),
        ] {
            let found = try mutants(of: "func f() { let v = \(value) }")
            XCTAssertTrue(found.contains("let v = \(constant)"), "\(value): \(found)")
        }
        XCTAssertEqual(
            try mutants(of: "func f() { let v = a < b && c < d }"),
            ["let v = a != b && c < d", "let v = false && c < d", "let v = a < b && c != d", "let v = a < b && false"]
        )
        XCTAssertEqual(try mutants(of: "func f() { v = a == b }"), ["v = true", "v = false"])
    }

    func test_parentheses_areKept_andACallsArgument_isReplaced() throws {
        XCTAssertEqual(try mutants(of: "func f() { let v = (a < b) }"), ["let v = (a != b)", "let v = (false)"])
        XCTAssertEqual(try mutants(of: "func f() { use(a == b, c) }"), ["use(true, c)", "use(false, c)"])
        XCTAssertEqual(
            try mutants(of: "func f() { let v = (a == b) == c }"),
            ["let v = true", "let v = (true) == c", "let v = (false) == c", "let v = false"]
        )
    }

    // A `try` or `await` over the comparison alone goes with it, as `try false` warns that nothing throws. Hoisted over
    // more, it would be left over what may not throw either, so the comparison gets no constant.
    func test_aTryOrAwait_goesWithTheComparison_onlyWhenItCoversItAlone() throws {
        XCTAssertEqual(try mutants(of: "func f() throws { let v = try load() < b }"), [
            "let v = try load() != b", "let v = false",
        ])
        XCTAssertEqual(try mutants(of: "func f() async throws { let v = try await load() == b }"), [
            "let v = true", "let v = false",
        ])
        XCTAssertEqual(try mutants(of: "func f() throws { let v = try load() < b && check() }"), [
            "let v = try load() != b && check()",
        ])
        XCTAssertEqual(try mutants(of: "func f() throws -> Int { try load() > 1 ? 10 : 20 }"), [
            "try load() != 1 ? 10 : 20",
        ])
        XCTAssertEqual(try mutants(of: "func f() async -> Int { await load() == 1 ? 10 : 20 }"), [
            "await load() != 1 ? 10 : 20",
        ])
        // Written after the first operand, it covers that operand alone.
        XCTAssertEqual(try mutants(of: "func f() throws { let v = a < b && (try check()) }"), [
            "let v = a != b && (try check())", "let v = false && (try check())",
        ])
        XCTAssertEqual(try changes(in: "func f() throws { let v = try load() < b }"), [
            "< → !=", "try load() < b → false",
        ])
        XCTAssertEqual(
            try mutants(of: "func f() throws { let v = try! load() == b }"),
            ["let v = true", "let v = false"]
        )
        XCTAssertEqual(try mutants(of: "func f() throws { let v = (try load()) == b }"), [
            "let v = true", "let v = false",
        ])
        // A `try?` can't go, as what it gives is an optional, and can't stay over a constant, which doesn't throw.
        XCTAssertEqual(try mutants(of: "func f() { let v = try? load() < b }"), [
            "let v = try? load() != b",
        ])
        XCTAssertEqual(try mutants(of: "func f() { if let v = try? load() == b { use(v) } }"), [
            "if let v = try? load() != b { use(v) }",
        ])
    }

    // A comment beside the comparison stays where it was, and a comment after it can't take in what follows.
    func test_theTriviaAroundTheComparison_isKept() throws {
        XCTAssertEqual(
            try mutants(of: """
            func f() -> Bool {
                return /* why */ a < b // because
            }
            """),
            ["return /* why */ a != b // because", "return /* why */ false // because"]
        )
        XCTAssertEqual(
            try mutants(of: """
            func f() -> Bool {
                return a == b /* when */ && c
            }
            """),
            ["return true /* when */ && c", "return false /* when */ && c"]
        )
    }

    func test_aComparisonOverSeveralLines_isReplacedWhole_andGivenOnOneLine() throws {
        let schemata = try visitor(walking: """
        func f() -> Bool {
            return a ==
                // the other
                b
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.snapshot.before), ["a == // the other b", "a == // the other b"])
        XCTAssertEqual(
            schemata.map { collapsingWhitespace($0.syntaxMutation.description) },
            ["return true", "return false"]
        )
        XCTAssertEqual(schemata.map(\.position.line), [2, 4])
    }

    // `let x=a<b` would otherwise become `let x=false`, which is fine, but a name next to it would join it.
    func test_aConstantTouchingNothing_staysAsTight() throws {
        XCTAssertEqual(try mutants(of: "func f() { let x=a<b }"), ["let x=a!=b", "let x=false"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { return(a<=b) }"), ["return(true)", "return(a==b)"])
    }
}
