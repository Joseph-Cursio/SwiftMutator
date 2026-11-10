@testable import muterCore
import XCTest

/// ReplaceBooleanValue replaces a Bool that is returned or stored with `true`, and in a second mutant with `false`.
final class ReplaceBooleanValueOperatorTests: MuterTestCase {
    func visitor(
        walking code: String,
        leavingComparisonsAlone: Bool = false,
        coverage: FileCoverage = .empty
    ) throws -> MuterVisitor {
        let source = try sourceCode(code)
        let visitor = ReplaceBooleanValueOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.leavesComparisonsAlone = leavingComparisonsAlone
        visitor.walk(source)
        return visitor
    }

    /// The values that get the pair of mutants, in the order of the file, each once. Fails unless each one has both.
    func values(
        in code: String,
        leavingComparisonsAlone: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        let schemata = try visitor(walking: code, leavingComparisonsAlone: leavingComparisonsAlone)
            .schemataMappings.mutationSchemata
        let trues = schemata.filter { $0.snapshot.after == "true" }.map(\.snapshot.before)
        let falses = schemata.filter { $0.snapshot.after == "false" }.map(\.snapshot.before)
        XCTAssertEqual(trues, falses, "each value gets both mutants", file: file, line: line)
        return trues
    }

    /// What each mutant makes of its statement list, in the order of the file, its spacing collapsed.
    func mutants(of code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { collapsingWhitespace($0.syntaxMutation.description) }
    }

    func test_aReturnedBool_becomesTrue_andInASecondMutantFalse() throws {
        XCTAssertEqual(
            try mutants(of: "func f() -> Bool { return items.isEmpty }"),
            ["return true", "return false"]
        )
    }

    // `true` is placed where the value starts and `false` where it ends, so each has a switch of its own.
    func test_eachMutant_hasAPlaceAndASwitchOfItsOwn_andItsSnapshotNamesTheValue() throws {
        let schemata = try visitor(walking: """
        func f() -> Bool {
            return items.isEmpty
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.mutationOperatorId), [.replaceBooleanValue, .replaceBooleanValue])
        XCTAssertEqual(schemata.map(\.position.line), [2, 2])
        XCTAssertEqual(schemata.map(\.position.column), [12, 25])
        XCTAssertEqual(schemata.map(\.snapshot), [
            .init(before: "items.isEmpty", after: "true", description: "replaced the Bool with true"),
            .init(before: "items.isEmpty", after: "false", description: "replaced the Bool with false"),
        ])
        XCTAssertNotEqual(schemata[0].id, schemata[1].id)
        XCTAssertEqual(
            MutantKey.keys(for: schemata, under: URL(fileURLWithPath: "/path/to")).map(\.occurrence),
            [0, 0]
        )
    }

    // MARK: A type written as Bool

    func test_whatAFunctionWrittenToReturnBoolReturns_counts() throws {
        XCTAssertEqual(try values(in: "func f() -> Bool { return items.isEmpty }"), ["items.isEmpty"])
        XCTAssertEqual(try values(in: "func f() -> Bool { items.isEmpty }"), ["items.isEmpty"])
        XCTAssertEqual(try values(in: "func f() -> Swift.Bool { flag }"), ["flag"])
        XCTAssertEqual(try values(in: "func f() -> (Bool) { flag }"), ["flag"])
        XCTAssertEqual(
            try values(in: "func f() -> Bool { if a { return check(a) }; return check(b) }"),
            ["check(a)", "check(b)"]
        )
    }

    func test_whatAGetterOrSubscriptWrittenAsBoolReturns_counts() throws {
        XCTAssertEqual(try values(in: "struct S { var isReady: Bool { flag } }"), ["flag"])
        XCTAssertEqual(try values(in: "struct S { var isReady: Bool { return flag } }"), ["flag"])
        XCTAssertEqual(
            try values(in: "struct S { var isReady: Bool { get { flag } set { flag = newValue } } }"),
            ["flag"]
        )
        XCTAssertEqual(try values(in: "struct S { var isReady: Bool { get throws { try load() } } }"), ["try load()"])
        XCTAssertEqual(try values(in: "struct S { subscript(i: Int) -> Bool { items[i] } }"), ["items[i]"])
        XCTAssertEqual(
            try values(in: "struct S { subscript(i: Int) -> Bool { get { return items[i] } } }"),
            ["items[i]"]
        )
    }

    func test_whatAClosureWrittenToReturnBoolReturns_counts() throws {
        XCTAssertEqual(try values(in: "let p = { (x: Int) -> Bool in check(x) }"), ["check(x)"])
        XCTAssertEqual(try values(in: "let p = { (x: Int) -> Bool in return check(x) }"), ["check(x)"])
        XCTAssertEqual(try values(in: "func f() { items.filter { x -> Bool in check(x) } }"), ["check(x)"])
    }

    func test_aBindingAnnotatedAsBool_counts() throws {
        XCTAssertEqual(try values(in: "func f() { let ok: Bool = check() }"), ["check()"])
        XCTAssertEqual(try values(in: "func f() { var ok: Swift.Bool = flag }"), ["flag"])
    }

    // MARK: An operator that makes a Bool

    func test_aComparisonOrLogicalOperator_counts_withNoTypeOrABoolOrOptionalBoolWritten() throws {
        for value in [
            "a == b", "a != b", "a < b", "a <= b", "a > b", "a >= b", "a === b", "a !== b",
            "a && b", "a || b", "!visible", "!items.isEmpty", "a + 1 < b", "a < b && c", "a.count == b.count",
        ] {
            XCTAssertEqual(try values(in: "func f() { let x = \(value) }"), [value], value)
        }
        XCTAssertEqual(try values(in: "func f() -> Bool? { a < b }"), ["a < b"])
        XCTAssertEqual(try values(in: "func f() { let x: Bool? = a < b }"), ["a < b"])
        for type in [
            "Bool!", "Swift.Bool?", "Swift.Bool!", "(Bool)?", "(Bool?)", "Optional<Bool>", "Optional<Swift.Bool>",
        ] {
            XCTAssertEqual(try values(in: "func f() { let x: \(type) = a < b }"), ["a < b"], type)
        }
        XCTAssertEqual(try values(in: "func f() -> Optional<(Bool)> { a < b }"), ["a < b"])
    }

    // Any other type written says the operator is an overload that gives that type, as a query builder's does, where
    // neither `true` nor `false` compiles.
    func test_anOperatorUnderAWrittenTypeOtherThanBool_doesntCount() throws {
        for code in [
            "func f() -> Int { a == b }",
            "func f() -> Int { a < b }",
            "func f() -> SQLExpression { a == b }",
            "func f() -> Expression<Bool> { return a == b }",
            "func f() { let x: Expression<Bool> = a >= b }",
            "func f() { let q: Query = a == b }",
            "struct S { var x: Binding<Bool> { !$y } }",
            "struct S { var p: Predicate { a < b } }",
            "func f() -> [Bool] { a < b }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // The tree isn't folded, so the operators' precedence says which one is worked out last.
    func test_aValueWhoseLastOperatorDoesntMakeABool_doesntCount() throws {
        for value in ["a < b ? c : d", "flag ?? (a < b)", "a + b", "x as Bool", "f(a < b)", "items.contains(a == b)"] {
            XCTAssertEqual(try values(in: "func f() { let x = \(value) }"), [], value)
        }
    }

    // `<=>` isn't in the standard table, so its precedence isn't known, nor what it gives.
    func test_anOperatorTheStandardTableDoesntHold_countsOnlyByAWrittenType() throws {
        XCTAssertEqual(try values(in: "func f() { let x = a <=> b }"), [])
        XCTAssertEqual(try values(in: "func f() { let x = a == b <=> c }"), [])
        XCTAssertEqual(try values(in: "func f() -> Bool { a <=> b }"), ["a <=> b"])
    }

    func test_parenthesesTryAndAwait_areSeenThrough() throws {
        XCTAssertEqual(try values(in: "func f() { let x = (a < b) }"), ["(a < b)"])
        XCTAssertEqual(try values(in: "func f() throws { let x = try load() < b }"), ["try load() < b"])
        XCTAssertEqual(try values(in: "func f() { let x = try! load() < b }"), ["try! load() < b"])
        XCTAssertEqual(try values(in: "func f() async { let x = await load() == b }"), ["await load() == b"])
        XCTAssertEqual(
            try values(in: "func f() async throws { let x = try await (load() && b) }"),
            ["try await (load() && b)"]
        )
        XCTAssertEqual(try values(in: "func f() async throws -> Bool { try await load() }"), ["try await load()"])
    }

    // `try?` makes an optional, which a later line may unwrap: `true` in its place doesn't compile there.
    func test_tryQuestionMark_isNotSeenThrough() throws {
        XCTAssertEqual(try values(in: "func f() { let x = try? load() < b }"), [])
    }

    // MARK: How the value is replaced

    // A comment beside the value stays where it was, and a comment after it can't take in what follows.
    func test_theTriviaAroundTheValue_isKept() throws {
        XCTAssertEqual(
            try mutants(of: """
            func f() -> Bool {
                return /* why */ a < b // because
            }
            """),
            ["return /* why */ true // because", "return /* why */ false // because"]
        )
    }

    func test_aValueOverSeveralLines_isReplacedWhole_andGivenOnOneLine() throws {
        let schemata = try visitor(walking: """
        func f() -> Bool {
            return a &&
                // the second
                b
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.snapshot.before), ["a && // the second b", "a && // the second b"])
        XCTAssertEqual(
            schemata.map { collapsingWhitespace($0.syntaxMutation.description) },
            ["return true", "return false"]
        )
        XCTAssertEqual(schemata.map(\.position.line), [2, 4])
    }

    // `return(a < b)` would otherwise become `returntrue`.
    func test_aValueTouchingAKeyword_isKeptApartFromIt() throws {
        XCTAssertEqual(try mutants(of: "func f() -> Bool { return(a < b) }"), ["return true", "return false"])
        XCTAssertEqual(try mutants(of: "func f() { let x=a<b }"), ["let x=true", "let x=false"])
    }

    // MARK: Where the shared rules apply

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
