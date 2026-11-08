@testable import muterCore
import XCTest

/// ReplaceBooleanValue replaces a Bool that is returned or stored with `true`, and in a second mutant with `false`.
final class ReplaceBooleanValueOperatorTests: MuterTestCase {
    private func visitor(
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
    private func values(
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
    private func mutants(of code: String) throws -> [String] {
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

    // MARK: What doesn't count

    // The syntax tree has no types, and these hold no sign of a Bool.
    func test_aValueOfNoWrittenBoolAndNoOperator_doesntCount() throws {
        for code in [
            "func f() { let x = items.isEmpty }",
            "func f() { let x: Bool? = flag }",
            "func f() { let x: Bool! = flag }",
            "func f() -> Bool? { flag }",
            "func f() -> Optional<Bool> { flag }",
            "func f() -> some Equatable { flag }",
            "typealias Flag = Bool; func f() -> Flag { flag }",
            "func f<T>() -> T { flag }",
            "func f() -> Int { count }",
            "func f() { return g() }",
            "func f() { g() }",
            "func f() { let x = flag! }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // A literal is FlipBooleanLiteral's, and an `if` or `switch` expression is left alone, branches included.
    func test_aLiteral_andAnIfOrSwitchExpression_areLeftAlone() throws {
        for code in [
            "func f() -> Bool { return true }",
            "func f() -> Bool { false }",
            "func f() -> Bool { (true) }",
            "func f() { let x: Bool = false }",
            "func f() -> Bool { if a { b } else { c } }",
            "func f() -> Bool { return switch a { case 1: b; default: c } }",
            "func f() { let x: Bool = if a { b } else { c } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        // A negated literal is a `!`, as a comparison of literals is a comparison.
        XCTAssertEqual(try values(in: "func f() { let x = !true }"), ["!true"])
    }

    // A closure that doesn't write its return type is mostly a predicate passed to `filter`, `sorted` or `contains`.
    func test_aClosureThatDoesntWriteItsReturnType_isLeftAlone() throws {
        for code in [
            "func f() { items.filter { $0 > 1 } }",
            "func f() { items.filter { x in x > 1 } }",
            "func f() { items.filter { x in return x > 1 } }",
            "func f() { items.sorted { (a: Int, b: Int) in a < b } }",
            "func f() { _ = #Predicate<Item> { $0.count > 1 } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // An untyped closure's one expression is the closure's, even inside a function or getter that returns a Bool.
    func test_anUntypedClosuresOneExpression_isItsOwn_insideABoolFunctionOrGetter() throws {
        XCTAssertEqual(
            try values(in: "func f() -> Bool { items.contains { $0.isReady } }"),
            ["items.contains { $0.isReady }"]
        )
        XCTAssertEqual(
            try values(in: "struct S { var ok: Bool { items.contains { item in item.isReady } } }"),
            ["items.contains { item in item.isReady }"]
        )
    }

    // A binding counts at any scope, inside a closure that leaves its type to be inferred as well.
    func test_aBindingInsideAnUntypedClosure_counts() throws {
        XCTAssertEqual(try values(in: "func f() { items.forEach { x in let big = x > 1; use(big) } }"), ["x > 1"])
    }

    // A `return` is the innermost closure's or function's, whatever is around it.
    func test_aReturnInANestedClosureOrFunction_isItsOwn() throws {
        XCTAssertEqual(
            try values(in: """
            func f() -> Bool {
                let found = items.first { item in
                    return item.isReady
                }
                return found.isEmpty
            }
            """),
            ["found.isEmpty"]
        )
        XCTAssertEqual(
            try values(in: """
            func f() -> Bool {
                func count() -> Int { return items.count }
                return count() > 1
            }
            """),
            ["count() > 1"]
        )
        XCTAssertEqual(
            try values(in: """
            func f() -> Int {
                let isLarge = { (x: Int) -> Bool in x > limit }
                return isLarge(1) ? 1 : 0
            }
            """),
            ["x > limit"]
        )
    }

    // An initializer, a setter and an observer return nothing.
    func test_whatReturnsNothing_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "struct S { init?() { if a < b { return nil }; return } }"), [])
        XCTAssertEqual(try values(in: "func f() { return }"), [])
        XCTAssertEqual(
            try values(in: "struct S { var x: Bool { get { flag } set { flag = newValue == other } } }"),
            ["flag"],
            "the getter's value, but not the setter's assignment"
        )
        XCTAssertEqual(
            try values(in: "struct S { var x: Bool = flag { didSet { if x { return } } } }"),
            ["flag"],
            "the property's value, but nothing in its observer"
        )
    }

    // A binding of one name: not `if let`, `guard let` or `case let`, a tuple's names, `_`, nor an assignment.
    func test_onlyABindingOfOneName_counts() throws {
        for code in [
            "func f() { if let x = a < b {} }",
            "func f() { guard let x = a < b else { return } }",
            "func f() { if case let x = a < b {} }",
            "func f() { let (x, y) = (a < b, c) }",
            "func f() { let _ = a < b }",
            "func f() { x = a < b }",
            "func f(x: Bool = a < b) {}",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try values(in: "func f() { let x = a < b, y = c, z = !d }"), ["a < b", "!d"])
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

    // MARK: RelationalOperatorReplacement's mutants

    // That operator replaces such a comparison with its constants, and with the swap it gives an ordering comparison
    // they stand for this pair: where `a < b` is false, its swap `a != b` is true wherever `true` is wrong too.
    func test_aComparison_isLeftToRelationalOperatorReplacement_whenThatOperatorIsOn() throws {
        for value in [
            "a == b", "a != b", "a < b", "a <= b", "a > b", "a >= b", "a + 1 < b", "(a < b)", "a.count == b.count",
        ] {
            let code = "func f() { let x = \(value) }"
            XCTAssertEqual(try values(in: code, leavingComparisonsAlone: true), [], value)
            XCTAssertEqual(try values(in: code), [value], value)
        }
        for code in [
            "func f() -> Bool { return a < b }",
            "func f() -> Bool { a == b }",
            "func f() throws -> Bool { try load() >= b }",
            "func f() async -> Bool { await load() != b }",
            "func f() { let x: Bool = a <= b }",
            "func f() { let x: Bool? = a > b }",
        ] {
            XCTAssertEqual(try values(in: code, leavingComparisonsAlone: true), [], code)
        }
    }

    // That operator leaves out all of a comparison's mutants when a directive leaves out one, here its swap, placed
    // where the operator's leading trivia starts, after `x)`, and then nothing stands for this pair, whose places,
    // where the value starts and ends, the directive doesn't reach.
    func test_aComparisonWhoseMutantsADirectiveLeavesOut_staysThisOperators() throws {
        let code = """
        func f() -> Bool {
            return load(
                // muter:disable-next-line
                x)
                < b
        }
        """
        XCTAssertEqual(
            try values(in: code, leavingComparisonsAlone: true),
            ["load( // muter:disable-next-line x) < b"]
        )
    }

    // `&&`, `||`, `!` and an identity check are this operator's still, and so is a comparison under any of them.
    func test_everythingElse_staysThisOperators_besideRelationalOperatorReplacement() throws {
        for value in [
            "a === b", "a !== b", "a && b", "a < b && c", "a == b || c", "!(a < b)", "!visible", "a < b ? c : d",
        ] {
            let code = "func f() -> Bool { \(value) }"
            XCTAssertEqual(try values(in: code, leavingComparisonsAlone: true), [value], value)
        }
        XCTAssertEqual(
            try values(in: "func f() -> Bool { items.isEmpty }", leavingComparisonsAlone: true),
            ["items.isEmpty"]
        )
        // An operator the standard table doesn't hold isn't known to be a comparison.
        XCTAssertEqual(
            try values(in: "func f() -> Bool { a <> b == c }", leavingComparisonsAlone: true),
            ["a <> b == c"]
        )
    }

    // MARK: Where the shared rules apply

    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() {
            // muter:disable
            let x = a < b
            // muter:enable
            let y = a > b
        }
        """), ["a > b"])
    }

    // The tag can sit beside the value itself, so it has to be read before the value is.
    func test_aDisableTagBesideTheValue_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Bool {
            return
                // muter:disable
                a < b
        }
        """), [])
    }

    // The `false` mutant is placed where the value ends, after a tag for the next line: both are left out, not one.
    func test_aDisableNextLineTagInsideAValueOverSeveralLines_leavesOutBothOrNeither() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Bool {
            return a &&
                // muter:disable-next-line
                b
        }
        """), [])
    }

    func test_aValueInACompilerDirectivesCode_counts() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Bool {
            #if DEBUG
            return a < b
            #else
            return a > b
            #endif
        }
        """), ["a < b", "a > b"])
    }

    // A mutant in a macro's arguments is switched around the macro, as other operators' are.
    func test_aValueInAMacrosArguments_counts() throws {
        XCTAssertEqual(
            try values(in: "func f() { #expect(items.allSatisfy { (x: Int) -> Bool in x > 1 }) }"),
            ["x > 1"]
        )
    }

    func test_aStoredPropertysAStaticsAndAGlobalsValue_areSwitchedInTheValue() throws {
        let visitor = try visitor(walking: """
        struct S {
            var isLarge = size > 1
            static let isDebug: Bool = Environment.isDebug
            lazy var isEmpty = items.count == 0
        }
        let isQuiet = level < 2
        """)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 8)
        XCTAssertEqual(visitor.droppedMutants, [])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Bool {
                if a {
                    return b < c
                }
                return b > c
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5, 5])
    }

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
