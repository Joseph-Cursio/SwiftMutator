@testable import muterCore
import TestingExtensions
import XCTest

/// RelationalOperatorReplacement gives each comparison the mutants of Kaminski, Ammann and Offutt's sufficient set: an
/// ordering comparison's operator swapped for `!=` or `==`, and the comparison replaced with `false` or `true`; an
/// equality check replaced with `true`, and in a second mutant with `false`.
final class ROROperatorTests: MuterTestCase {
    private lazy var sourceWithConditionalLogic = fixtureSource(
        at: "\(mutationExamplesDirectory)/RelationalOperatorReplacement/sampleWithConditionalOperators.swift"
    )

    private lazy var sourceWithoutMutableCode = fixtureSource(
        at: "\(fixturesDirectory)/sourceWithoutMutableCode.swift"
    )

    private lazy var conditionalConformanceConstraints = fixtureSource(
        at: "\(mutationExamplesDirectory)/RelationalOperatorReplacement/conditionalConformanceConstraints.swift"
    )

    private func visitor(walking code: String, coverage: FileCoverage = .empty) throws -> MuterVisitor {
        let source = try sourceCode(code)
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.walk(source)
        return visitor
    }

    /// What each mutant makes of its statement list, in the order of the file, its spacing collapsed.
    private func mutants(of code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { collapsingWhitespace($0.syntaxMutation.description) }
    }

    /// What each mutant puts in place of the code it replaces, in the order of the file.
    private func changes(in code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { "\($0.snapshot.before) → \($0.snapshot.after)" }
    }

    func test_visitor() throws {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: sourceWithConditionalLogic.code)
        )

        visitor.walk(sourceWithConditionalLogic.code)

        let actualSchematas = visitor.schemataMappings

        AssertSnapshot(actualSchematas.description)
    }

    func test_visitorOnFileWithoutOperator() {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: sourceWithoutMutableCode
        )

        visitor.walk(sourceWithoutMutableCode.code)

        XCTAssertTrue(visitor.schemataMappings.isEmpty)
    }

    func test_ignoresFunctionDeclarations() throws {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: sourceWithConditionalLogic
        )

        visitor.walk(sourceWithConditionalLogic.code)

        XCTAssertFalse(visitor.schemataMappings.codeBlocks.contains("func < "))
        XCTAssertFalse(
            visitor.schemataMappings.mutationSchemata.contains { $0.syntaxMutation.description.contains("func !=") }
        )
    }

    func test_ignoresConditionalConformancesConstraints() {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: conditionalConformanceConstraints
        )

        visitor.walk(conditionalConformanceConstraints.code)

        XCTAssertTrue(visitor.schemataMappings.isEmpty)
    }

    func test_rewriter() {
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: sourceWithConditionalLogic
        )

        visitor.walk(sourceWithConditionalLogic.code)

        let actualSchematas = visitor.schemataMappings
        let rewriter = MuterRewriter(actualSchematas).rewrite(sourceWithConditionalLogic.code)

        AssertSnapshot(formatCode(rewriter.description))
    }

    func test_charOffsetCrash() throws {
        let source = try sourceCode(
            """
            if value == "バルーンの表示判定" {

            }
            """
        )

        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file.swift", code: source)
        )

        visitor.walk(source)

        let rewritten = MuterRewriter(visitor.schemataMappings)
            .rewrite(source)
        AssertSnapshot(formatCode(rewritten.description))
    }

    // The reparse of the mutated block was told where the edit is in characters, not UTF-8 bytes.
    // Multi-byte text on an earlier line put the edit before the comparison's statement, so the
    // reparse reused that statement unmutated: the mutant was the original, reported as survived.
    func test_mutatesAComparisonAfterMultiByteText() throws {
        let source = try sourceCode(
            """
            func matches(_ a: Int, _ b: Int) -> Bool {
                let label = "バルーンの表示判定"
                print(label)
                return a == b
            }
            """
        )
        let visitor = ROROperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source)
        )

        visitor.walk(source)

        let mutations = visitor.schemataMappings.mutationSchemata.map { $0.syntaxMutation.description.trimmed.inlined }
        XCTAssertEqual(mutations, [
            #"let label = "バルーンの表示判定" print(label) return true"#,
            #"let label = "バルーンの表示判定" print(label) return false"#,
        ])
    }

    // MARK: Each comparison's mutants

    func test_eachOrderingComparison_getsItsSwap_andItsConstant() throws {
        XCTAssertEqual(try changes(in: "func f() -> Bool { a < b }"), ["< → !=", "a < b → false"])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a > b }"), ["> → !=", "a > b → false"])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a <= b }"), ["a <= b → true", "<= → =="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a >= b }"), ["a >= b → true", ">= → =="])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { a < b }"), ["a != b", "false"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { a >= b }"), ["true", "a == b"])
    }

    func test_eachEqualityCheck_getsBothConstants_andNoSwap() throws {
        XCTAssertEqual(try changes(in: "func f() -> Bool { a == b }"), ["a == b → true", "a == b → false"])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a != b }"), ["a != b → true", "a != b → false"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { return a != b }"), ["return true", "return false"])
    }

    // Nothing swaps an identity check, and an operator the standard library doesn't declare could be anything.
    func test_identityChecksAndOtherOperators_areLeftAlone() throws {
        for code in [
            "func f() -> Bool { a === b }",
            "func f() -> Bool { a !== b }",
            "func f() -> Bool { a <=> b }",
            "func f() -> Bool { a ~= b }",
            "func f() -> Int { a + b }",
        ] {
            XCTAssertEqual(try changes(in: code), [], code)
        }
    }

    // `true` is placed where the comparison starts, and `false` where it ends, so that each has a switch of its own,
    // apart from the swap's, at the operator.
    func test_eachMutant_hasAPlaceAndASwitchOfItsOwn_andItsSnapshotNamesTheComparison() throws {
        let equality = try visitor(walking: """
        func f() -> Bool {
            return a.count == b
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(equality.map(\.mutationOperatorId), [.ror, .ror])
        XCTAssertEqual(equality.map(\.position.line), [2, 2])
        XCTAssertEqual(equality.map(\.position.column), [12, 24])
        XCTAssertEqual(equality.map(\.snapshot), [
            .init(before: "a.count == b", after: "true", description: "replaced the comparison with true"),
            .init(before: "a.count == b", after: "false", description: "replaced the comparison with false"),
        ])
        XCTAssertNotEqual(equality[0].id, equality[1].id)

        let ordering = try visitor(walking: """
        func f() -> Bool {
            return a.count < b
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(ordering.map(\.position.column), [20, 23])
        XCTAssertEqual(ordering.map(\.snapshot), [
            .init(before: "<", after: "!=", description: "changed < to !="),
            .init(before: "a.count < b", after: "false", description: "replaced the comparison with false"),
        ])
        XCTAssertEqual(
            MutantKey.keys(for: equality + ordering, under: URL(fileURLWithPath: "/path/to")).map(\.occurrence),
            [0, 0, 0, 0]
        )
    }

    // MARK: What a constant replaces

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

    // MARK: Where a comparison gets no constant

    // A comparison whose value is thrown away is an overload with side effects, as Nimble's `expect(x) == 1`: a
    // literal there would be an unused value that tests nothing. The swap still changes what it is called with.
    func test_aComparisonThatIsAStatement_getsOnlyItsSwap() throws {
        XCTAssertEqual(try changes(in: "func f() { expect(x) == 1 }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { expect(x) != 1 }"), ["!= → =="])
        XCTAssertEqual(try changes(in: "func f() { expect(x) < 1 }"), ["< → !="])
        XCTAssertEqual(try changes(in: "func f() throws { try expect(x) >= 1 }"), [">= → =="])
        XCTAssertEqual(try changes(in: "func f() { work(); expect(x) == 1 }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() -> Void { expect(x) == 1 }"), ["== → !="])
        XCTAssertEqual(try changes(in: "struct S { init() { expect(x) == 1 } }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { if c { expect(x) == 1 } }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { switch c { case 1: expect(x) == 1; default: break } }"), [
            "== → !=",
        ])
        XCTAssertEqual(try changes(in: "expect(x) == 1"), ["== → !="])
    }

    // The one statement of a body that gives its value is that value: a closure's, whatever its type, as it is mostly
    // a predicate, a getter's, a function's that writes its return type, and a branch's of an `if` or `switch` that
    // is a value.
    func test_theOneStatementOfABodyThatGivesItsValue_getsItsConstants() throws {
        for code in [
            "func f() -> Bool { a == b }",
            "func f() { items.filter { _ in a == b } }",
            "func f() { items.filter { (x: Int) -> Bool in a == b } }",
            "struct S { var ok: Bool { a == b } }",
            "struct S { var ok: Bool { get { a == b } } }",
            "struct S { subscript(i: Int) -> Bool { a == b } }",
            "func f() { let v = if c { a == b } else { d } }",
            "func f() { let v = if c { d } else if e { a == b } else { d } }",
            "func f() -> Bool { if c { a == b } else { d } }",
            "func f() { let v = switch c { case 1: a == b; default: d } }",
        ] {
            XCTAssertEqual(try changes(in: code), ["a == b → true", "a == b → false"], code)
        }
    }

    // `while true` loops until the time limit, and the score counts such a timeout as a survivor, so a comparison
    // that decides a loop's condition gets no constant that makes it always true: its swap or its other constant is
    // left, and is wrong only where the negation is too.
    func test_aComparisonThatDecidesALoop_getsNoConstantThatKeepsItGoing() throws {
        XCTAssertEqual(try changes(in: "func f() { while a <= b {} }"), ["<= → =="])
        XCTAssertEqual(try changes(in: "func f() { while (a >= b) {} }"), [">= → =="])
        XCTAssertEqual(try changes(in: "func f() { while a != b {} }"), ["a != b → false"])
        XCTAssertEqual(try changes(in: "func f() { repeat {} while a == b }"), ["a == b → false"])
        XCTAssertEqual(try changes(in: "func f() { repeat {} while (a <= b) }"), ["<= → =="])
        XCTAssertEqual(try changes(in: "func f() throws { while try a == load() {} }"), ["try a == load() → false"])
        XCTAssertEqual(try changes(in: "func f() { while c || a == b {} }"), ["a == b → false"])
        XCTAssertEqual(try changes(in: "func f() { while !(a == b) {} }"), ["a == b → true"])
        XCTAssertEqual(try changes(in: "func f() { while !(a < b) {} }"), ["< → !="])
        // `false` ends the loop.
        XCTAssertEqual(try changes(in: "func f() { while a < b {} }"), ["< → !=", "a < b → false"])
        // The rest of the condition can still end the loop, and an `if` or `guard` doesn't loop.
        for code in [
            "func f() { while a == b, c {} }",
            "func f() { while a == b && c {} }",
            "func f() { while (a == b) && c {} }",
            "func f() { if a == b {} }",
            "func f() { guard a == b else { return } }",
            "func f() { while c { let v = a == b } }",
        ] {
            XCTAssertEqual(try changes(in: code), ["a == b → true", "a == b → false"], code)
        }
    }

    // An operator the standard table doesn't hold has no known precedence, so the comparison's extent isn't known.
    // Its swap is safe: `==` gets the swap it got before.
    func test_aSequenceTheStandardTableCantFold_getsOnlyTheSwap() throws {
        XCTAssertEqual(try changes(in: "func f() -> Bool { a <> b == c }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a <> b < c }"), ["< → !="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a < b == c }"), ["< → !=", "== → !="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { (a <> b) == c }"), [
            "(a <> b) == c → true", "(a <> b) == c → false",
        ])
    }

    // A closure that names no parameters takes as many as the highest `$` argument it uses says, so `{ $0 > 1 }` as
    // `{ false }` takes none, which doesn't compile where one is passed.
    func test_aComparisonHoldingAClosuresOnlyUseOfItsHighestArgument_getsOnlyItsSwap() throws {
        XCTAssertEqual(try changes(in: "func f() { items.filter { $0 > 1 } }"), ["> → !="])
        XCTAssertEqual(try changes(in: "func f() { items.sorted { $0 < $1 } }"), ["< → !="])
        XCTAssertEqual(try changes(in: "func f() { items.filter { $0 == 1 } }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { items.first { $0.count == 1 && $0.isReady } }"), [
            "$0.count == 1 → true", "$0.count == 1 → false",
        ])
        XCTAssertEqual(try changes(in: "func f() { pairs.sorted { $0.a < $1.a || $1.b > 2 } }"), [
            "< → !=", "$0.a < $1.a → false", "> → !=", "$1.b > 2 → false",
        ])
        XCTAssertEqual(try changes(in: "func f() { lists.filter { $0.filter { $0 > 1 }.count == 2 } }"), [
            "> → !=", "== → !=",
        ])
        XCTAssertEqual(try changes(in: "func f() { items.filter { x in x > 1 } }"), ["> → !=", "x > 1 → false"])
    }

    // MARK: Where the shared rules apply

    func test_aCompilerDirectivesCondition_isLeftAlone_howeverDeepItIs() throws {
        let source = try sourceCode("""
        func f(a: Int, b: Int) {
            #if !(swift(>=5.9) && VALUE == 1)
            run(a == b)
            #elseif (compiler(<6) || VALUE != 2)
            run(a != b)
            #endif
        }
        """)
        let visitor = ROROperator.Visitor(sourceCodeInfo: .init(path: "/path/to/file", code: source))

        visitor.walk(source)

        XCTAssertEqual(
            visitor.schemataMappings.mutationSchemata.map(\.position.line).sorted(),
            [3, 3, 5, 5]
        )
    }

    func test_anOperatorsDeclaration_isLeftAlone() throws {
        XCTAssertEqual(try changes(in: """
        struct V: Comparable {
            static func < (lhs: V, rhs: V) -> Bool { lhs.x < rhs.x }
            static func == (lhs: V, rhs: V) -> Bool { true }
        }
        infix operator <=>: ComparisonPrecedence
        """), ["< → !=", "lhs.x < rhs.x → false"])
    }

    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try changes(in: """
        func f() {
            // muter:disable
            let x = a < b
            // muter:enable
            let y = a == b
        }
        """), ["a == b → true", "a == b → false"])
    }

    // The `false` mutant is placed where the comparison ends, after a tag for the next line: all of a comparison's
    // mutants are left out, not some, as ReplaceBooleanValue leaves out both of a value's.
    func test_aDisableNextLineTagInsideAComparisonOverSeveralLines_leavesOutAllOrNone() throws {
        for code in [
            "func f() -> Bool {\n    return a ==\n        // muter:disable-next-line\n        b\n}",
            "func f() -> Bool {\n    return a\n        // muter:disable-next-line\n        < b\n}",
            "func f() -> Bool {\n    return a\n        // muter:disable-next-line\n        <= b\n}",
        ] {
            XCTAssertEqual(try changes(in: code), [], code)
        }
        let nextLine = "func f() -> Bool {\n    // muter:disable-next-line\n    let x = a < b\n    return a > b\n}"
        XCTAssertEqual(try changes(in: nextLine), ["> → !=", "a > b → false"])
    }

    // As with any other operator, code the tests never ran gets no mutant: the constants go by the operator, as the
    // swap does, so the right-hand side of `&&`, a closure of its own, is left out whole.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Bool {
                if a {
                    return b < c
                }
                return b == c
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5, 5])
    }

    func test_aStoredPropertysAndAGlobalsValue_areSwitchedInTheValue() throws {
        let visitor = try visitor(walking: """
        struct S {
            var isLarge = size > 1
            lazy var isEmpty = items.count == 0
        }
        let isQuiet = level < 2
        """)

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.count, 6)
        XCTAssertEqual(visitor.droppedMutants, [])
    }

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
