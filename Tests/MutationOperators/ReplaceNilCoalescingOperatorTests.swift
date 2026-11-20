@testable import muterCore
import XCTest

/// ReplaceNilCoalescing replaces a `??` term with its fallback, so the code always takes the value on the right.
final class ReplaceNilCoalescingOperatorTests: MuterTestCase {
    func visitor(walking code: String, coverage: FileCoverage = .empty) throws -> MuterVisitor {
        let source = try sourceCode(code)
        let visitor = ReplaceNilCoalescingOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.walk(source)
        return visitor
    }

    /// The terms replaced, in the order of the file.
    func values(in code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata.map(\.snapshot.before)
    }

    /// What each mutant makes of its statement list, in the order of the file, its spacing collapsed.
    func mutants(of code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { collapsingWhitespace($0.syntaxMutation.description) }
    }

    func test_aCoalescing_becomesItsFallback() throws {
        XCTAssertEqual(
            try mutants(of: "func f() -> String { return user.nickname ?? user.fullName }"),
            ["return user.fullName"]
        )
    }

    // One mutant, placed where the term starts, after its leading trivia.
    func test_theMutant_isPlacedWhereTheTermStarts_andItsSnapshotNamesTheTerm() throws {
        let schemata = try visitor(walking: """
        func f() -> String {
            return user.nickname ?? user.fullName
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.mutationOperatorId), [.replaceNilCoalescing])
        XCTAssertEqual(schemata.map(\.position.line), [2])
        XCTAssertEqual(schemata.map(\.position.column), [12])
        XCTAssertEqual(schemata.map(\.snapshot), [
            .init(
                before: "user.nickname ?? user.fullName",
                after: "user.fullName",
                description: "replaced the coalescing with its fallback"
            ),
        ])
    }

    // MARK: Chains

    // `??` is right-associative: the outer term starts at `a`, the inner one at `b`, so each has a switch of its own.
    func test_eachCoalescingOfAChain_getsItsOwnMutant() throws {
        let code = """
        func f() -> Int {
            a ?? b ?? c
        }
        """
        let schemata = try visitor(walking: code).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.snapshot.before), ["a ?? b ?? c", "b ?? c"])
        XCTAssertEqual(schemata.map(\.snapshot.after), ["b ?? c", "c"])
        XCTAssertEqual(try mutants(of: code), ["b ?? c", "a ?? c"])
        XCTAssertEqual(schemata.map(\.position.column), [5, 10])
        XCTAssertNotEqual(schemata[0].id, schemata[1].id)
        XCTAssertEqual(
            MutantKey.keys(for: schemata, under: URL(fileURLWithPath: "/path/to")).map(\.occurrence),
            [0, 0]
        )
    }

    func test_eachLinkOfALongerChain_dropsItsOwnLeftSide() throws {
        XCTAssertEqual(try mutants(of: "func f() -> Int { w ?? a ?? b ?? c }"), [
            "a ?? b ?? c", "w ?? b ?? c", "w ?? a ?? c",
        ])
    }

    func test_aChainOverSeveralLines_givesEachLinkOnOneLine_atItsOwnLine() throws {
        let schemata = try visitor(walking: """
        func f() -> Int {
            return a
                ?? b
                ?? c
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.snapshot.before), ["a ?? b ?? c", "b ?? c"])
        XCTAssertEqual(schemata.map(\.position.line), [2, 3])
        XCTAssertEqual(
            schemata.map { collapsingWhitespace($0.syntaxMutation.description) },
            ["return b ?? c", "return a ?? c"]
        )
        // `--changed-lines` reads these: each link spans the whole sequence, so a change to any of its lines keeps it.
        XCTAssertEqual(schemata.map(\.lines), [2...4, 2...4])
    }

    // MARK: Precedence

    // The term is what the standard operators' precedence makes it: `??` binds tighter than a comparison, `&&` and a
    // ternary, and looser than arithmetic and a cast.
    func test_aCoalescingAmongOtherOperators_isReplacedByItsPrecedence() throws {
        let table: [(code: String, expected: (terms: [String], mutants: [String]))] = [
            ("x ?? 0 + 1 < 5", (["x ?? 0 + 1"], ["0 + 1 < 5"])),
            ("a < b ?? c", (["b ?? c"], ["a < c"])),
            ("a ?? b == c ?? d", (["a ?? b", "c ?? d"], ["b == c ?? d", "a ?? b == d"])),
            ("a + b ?? c > 1", (["a + b ?? c"], ["c > 1"])),
            ("x as? Int ?? 0 > 1", (["x as? Int ?? 0"], ["0 > 1"])),
            ("p && q ?? r", (["q ?? r"], ["p && r"])),
            ("flag ? a ?? b : c", (["a ?? b"], ["flag ? b : c"])),
            ("flag ? c : a ?? b", (["a ?? b"], ["flag ? c : b"])),
            ("a ?? b ? c : d", (["a ?? b"], ["b ? c : d"])),
        ]
        for (code, (terms, mutants)) in table {
            let function = "func f() -> Bool { \(code) }"
            XCTAssertEqual(try values(in: function), terms, code)
            XCTAssertEqual(try self.mutants(of: function), mutants, code)
        }
    }

    func test_anAssignedCoalescing_isReplaced() throws {
        XCTAssertEqual(try mutants(of: "func f() { y = a ?? b }"), ["y = b"])
        XCTAssertEqual(try mutants(of: "func f() { y += a ?? b }"), ["y += b"])
    }

    // MARK: try and await

    // Folding hoists a leading `try` or `await` over the whole term, so it stays, and still covers the fallback.
    func test_aLeadingTry_staysOverTheFallback() throws {
        XCTAssertEqual(try mutants(of: "func g() throws -> Int { try a ?? f() }"), ["try f()"])
        XCTAssertEqual(try mutants(of: "func g() throws { let x = try cached() ?? load() }"), ["let x = try load()"])
        XCTAssertEqual(try mutants(of: "func g() throws -> Bool { try a ?? f() < 1 }"), ["try f() < 1"])
        XCTAssertEqual(try mutants(of: "func g() throws { x = try a ?? f() }"), ["x = try f()"])
    }

    // The fallback is in the `??`'s autoclosure, which can't wait, so an `await` stays only over a call outside the
    // term.
    func test_aLeadingAwait_staysOverACallOutsideTheTerm() throws {
        XCTAssertEqual(
            try mutants(of: "func g() async -> Bool { await peek() ?? 0 == fetch() }"),
            ["await 0 == fetch()"]
        )
        XCTAssertEqual(
            try mutants(of: "func g() async -> Int { await total(of: peek() ?? 0) }"),
            ["await total(of: 0)"]
        )
    }

    func test_aTryInsideTheFallback_movesWithIt() throws {
        XCTAssertEqual(try mutants(of: "func g() throws -> Int { a ?? (try f()) }"), ["(try f())"])
    }

    func test_aTryQuestionMarkOnTheLeft_goesWithTheLeftSide() throws {
        XCTAssertEqual(try mutants(of: "func g() -> Int { (try? load()) ?? fallback }"), ["fallback"])
    }

    // A `try` hoisted over more than the term keeps the calls after it.
    func test_aTryOverMoreThanTheTerm_staysWhileItCoversACall() throws {
        XCTAssertEqual(
            try mutants(of: "func g() throws -> Bool { try a() ?? b < c && d() }"),
            ["try b < c && d()"]
        )
        XCTAssertEqual(try mutants(of: "func g() throws -> Int { try f(a() ?? 0) }"), ["try f(0)"])
    }

    // MARK: Where it is

    // The switch goes in the closure's own statements.
    func test_aCoalescingInAClosure_isReplaced() throws {
        XCTAssertEqual(try mutants(of: "func f() { items.map { $0.nick ?? $0.name } }"), ["$0.name"])
        XCTAssertEqual(try mutants(of: "func f() { items.map { (x: Int?) -> Int in x ?? y } }"), ["y"])
        XCTAssertEqual(try mutants(of: "func f() -> Int { { a ?? b }() }"), ["b"])
    }

    func test_aCoalescingInAStringInterpolation_isReplaced() throws {
        XCTAssertEqual(try mutants(of: #"func f() -> String { "\(name ?? fallback)!" }"#), [#""\(fallback)!""#])
    }

    // MARK: Trivia

    func test_theTriviaAroundTheTerm_isKept() throws {
        XCTAssertEqual(
            try mutants(of: """
            func f() -> Int {
                return /* why */ a ?? b // because
            }
            """),
            ["return /* why */ b // because"]
        )
    }

    func test_aTermOverSeveralLines_isReplacedWhole_andGivenOnOneLine() throws {
        let code = """
        func f() -> Int {
            return first(
                of: items
            ) ?? fallback
        }
        """
        XCTAssertEqual(try values(in: code), ["first( of: items ) ?? fallback"])
        XCTAssertEqual(try mutants(of: code), ["return fallback"])
    }

    func test_aTermWithoutSpaces_isReplaced_apartFromWhatItWouldTouch() throws {
        XCTAssertEqual(try mutants(of: "func f() { let x=a ?? b }"), ["let x=b"])
        XCTAssertEqual(try mutants(of: "func f() -> Int { return(x) ?? y }"), ["return y"])
        XCTAssertEqual(try mutants(of: "func f() { x=a ?? -1 }"), ["x=(-1)"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { x<a ?? -1 }"), ["x<(-1)"])
        // `=.` and `==.` would be operators too.
        XCTAssertEqual(try mutants(of: "func f() { x=a ?? .low }"), ["x=(.low)"])
        XCTAssertEqual(try mutants(of: "func f() -> Bool { x==a ?? .low }"), ["x==(.low)"])
        // `return.low` is a `return` of `.low`.
        XCTAssertEqual(try mutants(of: "func f() -> Level { return(a) ?? .low }"), ["return.low"])
    }

    // The snapshot's fallback is in the parentheses the mutant adds, so a report shows the code that was tested, but
    // not with the space that keeps it off a name.
    func test_aTermWithoutSpaces_hasTheFallbackAsTheMutantWritesIt_inItsSnapshot() throws {
        let table: [(code: String, after: String)] = [
            ("func f() { x=a ?? -1 }", "(-1)"),
            ("func f() { x=a ?? .low }", "(.low)"),
            ("func f() -> Int { return(x) ?? y }", "y"),
            ("func f() -> Int { return x ?? -1 }", "-1"),
        ]
        for (code, after) in table {
            let schemata = try visitor(walking: code).schemataMappings.mutationSchemata
            XCTAssertEqual(schemata.map(\.snapshot.after), [after], code)
        }
    }

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
