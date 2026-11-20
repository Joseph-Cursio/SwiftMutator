import XCTest

extension ReplaceNilCoalescingOperatorTests {
    // MARK: A fallback that takes its type from its place

    // `let y = x ?? 0` as `let y = 0` makes `y` an Int, whatever `x` held, and `let y = nil` doesn't compile.
    func test_aFallbackThatTakesItsTypeFromItsPlace_inAnUnannotatedBinding_isLeftAlone() throws {
        let fallbacks = [
            "nil", "0", "0.5", "-1", #""""#, #""a""#, ##"#"a"#"##, #""\(a)""#, "[]", "[:]", "[1]", #"["a": 1]"#,
            "(0)", "/a/", ".zero", ".init(1)", ".make().value", "{ 0 }", "0 + 1", "(0 + 1)",
        ]
        for fallback in fallbacks {
            let code = "func f() { let y = x ?? \(fallback) }"
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    func test_aWholeValueInsideParenthesesOrEffectMarkers_inAnUnannotatedBinding_isLeftAlone() throws {
        for code in [
            "func f() { var y = x ?? 0 }",
            "func f() { let y = (x ?? 0) }",
            "func f() { let y = ((x ?? 0)) }",
            "func f() throws { let y = try x() ?? [] }",
            "func f() async { let y = await x() ?? [] }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    func test_aFallbackThatTakesItsTypeFromItsPlace_inAStoredPropertyAStaticOrAGlobal_isLeftAlone() throws {
        XCTAssertEqual(try values(in: """
        struct S {
            var a = x ?? 0
            static let b = y ?? ""
            lazy var c = z ?? []
        }
        let d = w ?? .zero
        """), [])
    }

    func test_aFallbackThatTakesItsTypeFromItsPlace_inAnOptionalBindingACaptureOrALoop_isLeftAlone() throws {
        for code in [
            "func f() { if let y = x ?? nil { use(y) } }",
            "func f() { guard let y = x ?? nil else { return } }",
            "func f() { while let y = x ?? nil { use(y) } }",
            "func f() { run { [y = x ?? 0] in use(y) } }",
            "func f() { for item in items ?? [] { use(item) } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // `(x ?? []).sorted()` as `([]).sorted()` has no element type: the commonest build error on SwiftProjectLint.
    func test_aFallbackThatTakesItsTypeFromItsPlace_asAMembersOrASubscriptsBase_isLeftAlone() throws {
        for code in [
            "func f() { use((x ?? []).sorted()) }",
            "func f() { for y in (x ?? []).sorted() where y > 0 { use(y) } }",
            "func f() { let n = (x ?? [:]).keys }",
            "func f() { use((x ?? []).contains { $0 == 1 }) }",
            "func f() { use((x ?? [])[0]) }",
            // The `try` still covers a call, so only this rule leaves it alone.
            "func f() throws { use((try load() ?? .init()).count) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // A closure that writes no return type takes it from what it gives.
    func test_aFallbackThatTakesItsTypeFromItsPlace_asWhatAClosureGives_isLeftAlone() throws {
        for code in [
            "func f() { use(items.flatMap { item in item.names ?? [] }) }",
            "func f() { use(items.map { item in item.size ?? .zero }) }",
            "func f() { use(items.map { item in item.lookup ?? nil }) }",
            "func f() { use(items.map { item in if item.ok { return item.names ?? [] }; return [] }) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    func test_aFallbackAsAMembersBaseOrWhatAClosureGives_isReplaced_whereItHasATypeOfItsOwnOrOneIsWritten() throws {
        XCTAssertEqual(try values(in: "func f() { use((x ?? others).sorted()) }"), ["x ?? others"])
        XCTAssertEqual(try values(in: "func f() { use(items.map { (item) -> [Int] in item.names ?? [] }) }"), [
            "item.names ?? []",
        ])
        // The closure's body has more than the one expression, so a `??` statement isn't what it returns.
        XCTAssertEqual(try values(in: "func f() { run { x ?? 0; done() } }"), ["x ?? 0"])
        // A number or string literal has a type of its own, `Int` or `String`, so these compile.
        XCTAssertEqual(try values(in: #"func f() { use((name ?? "").isEmpty) }"#), [#"name ?? """#])
        XCTAssertEqual(try values(in: "func f() { use((count ?? 0).description) }"), ["count ?? 0"])
        XCTAssertEqual(try values(in: "func f() { use((x ?? [1])[0]) }"), ["x ?? [1]"])
        XCTAssertEqual(try values(in: "func f() { use(items.map { item in item ?? 9 }) }"), ["item ?? 9"])
        // A `return` in a function inside a closure is the function's.
        XCTAssertEqual(try values(in: "func f() { run { func g() -> [Int] { return x ?? [] } } }"), ["x ?? []"])
    }

    // `true` and `false` are always Bools.
    func test_aBoolFallback_inAnUnannotatedBinding_isReplaced() throws {
        XCTAssertEqual(try mutants(of: "func f() { let y = x ?? true }"), ["let y = true"])
    }

    func test_aFallbackThatTakesItsTypeFromItsPlace_isReplaced_whereItsTypeIsGiven() throws {
        let table: [(code: String, mutants: [String])] = [
            ("func f() { let y: Double = x ?? 0 }", ["let y: Double = 0"]),
            ("func f() { use(x ?? 0) }", ["use(0)"]),
            (#"func f() { use(label: x ?? "") }"#, [#"use(label: "")"#]),
            ("func f() -> Int { return x ?? 0 }", ["return 0"]),
            ("func f() -> Int { x ?? 0 }", ["0"]),
            ("func f() { let y = (x ?? 0) * 2.5 }", ["let y = (0) * 2.5"]),
            ("func f() { if let y: Int = x ?? nil { use(y) } }", ["if let y: Int = nil { use(y) }"]),
            ("func f() { let y = x ?? z ?? 0 }", ["let y = z ?? 0", "let y = x ?? 0"]),
        ]
        for (code, mutants) in table {
            XCTAssertEqual(try self.mutants(of: code), mutants, code)
        }
        XCTAssertEqual(try values(in: #"func f(_ v: String? = x ?? "none") {}"#), [#"x ?? "none""#])
        XCTAssertEqual(try values(in: "func f() { let a = x ?? 0, b: Int = y ?? 0 }"), ["y ?? 0"])
    }

    func test_aFallbackWithATypeOfItsOwn_inAnUnannotatedBinding_isReplaced() throws {
        XCTAssertEqual(try mutants(of: "func f() { let y = x ?? fallback() }"), ["let y = fallback()"])
        XCTAssertEqual(try mutants(of: "func f() { let y = x ?? Item.empty }"), ["let y = Item.empty"])
        XCTAssertEqual(try mutants(of: "func f() { for item in items ?? others { use(item) } }"), [
            "for item in others { use(item) }",
        ])
    }

    // MARK: A marker left over nothing

    // `try load() ?? 0` as `try 0` warns that nothing throws inside the `try`.
    func test_aTryOrAwaitThatWouldCoverNoCall_isLeftAlone() throws {
        for code in [
            "func f() throws -> Int { try load() ?? 0 }",
            "func f() throws -> Int { try load() ?? fallback }",
            "func f() -> Int { try! load() ?? 0 }",
            "func f() -> Int? { try? load() ?? 0 }",
            "func f() async -> Int { await load() ?? 0 }",
            "func f() async -> Int { await load() ?? backup() }",
            "func f() async throws -> Int { try await load() ?? backup() }",
            "func f() async -> Int { await (load() ?? backup()) }",
            "func f() throws -> Int { try (load() ?? 0) }",
            "func f() throws -> Bool { try load() ?? 0 < 1 }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    func test_aTryThatStillCoversACallOrAMember_isKept() throws {
        XCTAssertEqual(try mutants(of: "func f() throws -> Int { try load() ?? backup() }"), ["try backup()"])
        XCTAssertEqual(try mutants(of: "func f() throws -> Int { try load() ?? cache.value }"), ["try cache.value"])
        XCTAssertEqual(try mutants(of: "func f() throws -> Int { try load() ?? cache[0] }"), ["try cache[0]"])
    }

    // A `try` written over the first operand of an enclosing sequence covers the whole of it once folded, as
    // `try 1 + (a() ?? 0)` is `try (1 + (a() ?? 0))`, so `try 1 + (0)` would warn too.
    func test_aMarkerAnEnclosingSequenceHoistsOverTheTerm_isCheckedToo() throws {
        for code in [
            "func f() throws -> Int { try 1 + (a() ?? 0) }",
            "func f() throws -> Int { try total + (a() ?? 0) }",
            "func f() async -> Int { await x + (peek() ?? 0) }",
            "func f() async -> Int { await x + (peek() ?? backup()) }",
            "func f() throws -> Int { try 1 + 2 * (a() ?? 0) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try mutants(of: "func f() throws -> Int { try b() + (a() ?? 0) }"), ["try b() + (0)"])
        XCTAssertEqual(try mutants(of: "func f() throws -> Int { try 1 + (a() ?? b()) }"), ["try 1 + (b())"])
        XCTAssertEqual(try mutants(of: "func f() -> Int { 1 + (a ?? 0) }"), ["1 + (0)"])
    }

    // MARK: A closure's arguments

    // `{ $0.nick ?? fallback }` as `{ fallback }` takes no argument, which doesn't compile where one is passed.
    func test_theOnlyUseOfAClosuresHighestArgument_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "func f() { items.map { $0.nick ?? fallback } }"), [])
        XCTAssertEqual(try values(in: "func f() { pairs.map { $1 ?? $0 } }"), [])
        XCTAssertEqual(try values(in: "func f() { pairs.map { $0 ?? $1 } }"), ["$0 ?? $1"])
        XCTAssertEqual(try values(in: "func f() { items.map { x in x ?? fallback } }"), ["x ?? fallback"])
    }

    // MARK: A fallback assigned to itself

    // A merge keeps what it had with `one = other.one ?? one`, which as `one = one` doesn't compile: Swift won't
    // assign a variable to itself, nor `self.one` to `self.one` (BonMot's `add(other:)`).
    func test_aFallbackThatIsWhatTheExpressionIsAssignedTo_isLeftAlone() throws {
        for code in [
            "func f() { one = other.one ?? one }",
            "func f() { self.one = other.one ?? self.one }",
            "func f() { one = other.one ?? (one) }",
            "func f() { `default` = other.value ?? `default` }",
            "func f() throws { one = try other.one() ?? one }",
            // The whole term in parentheses, where the assignment is outside the folded sequence.
            "func f() { one = (other.one ?? one) }",
            "func f() { self.one = ((other.one ?? self.one)) }",
            "func f() throws { one = try (other.one() ?? one) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // Swift refuses only those two shapes, written alike on both sides.
    func test_aFallbackThatIsntWhatTheExpressionIsAssignedTo_isReplaced() throws {
        let table: [(code: String, value: String)] = [
            ("func f() { one = other.one ?? two }", "other.one ?? two"),
            ("func f() { b.v = c.v ?? d.v }", "c.v ?? d.v"),
            // A parameter that hides the property: `self.timeout = timeout` compiles.
            ("init(timeout: Int, config: C?) { self.timeout = config?.timeout ?? timeout }",
             "config?.timeout ?? timeout"),
            // A property of a property, or of a type, or one reached through an implicit `self`, may be assigned to
            // itself, as may a subscript.
            ("func f() { b.v = c.v ?? b.v }", "c.v ?? b.v"),
            ("func f() { self.a.b = x ?? self.a.b }", "x ?? self.a.b"),
            ("func f() { Config.shared = loaded ?? Config.shared }", "loaded ?? Config.shared"),
            ("func f() { items[0] = other ?? items[0] }", "other ?? items[0]"),
            // Only when it's the whole value: `one = (one) + 1` compiles, and so does `one += one`.
            ("func f() { one = (other.one ?? one) + 1 }", "other.one ?? one"),
            ("func f() { one += other.one ?? one }", "other.one ?? one"),
        ]
        for (code, value) in table {
            XCTAssertEqual(try values(in: code), [value], code)
        }
    }

    // MARK: What isn't a `??` term

    func test_anAssigningCoalescing_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "func f() { x ??= y }"), [])
        XCTAssertEqual(try values(in: "func f() { x ??= a ?? b }"), [])
    }

    func test_aSequenceWithAnOperatorTheProjectDeclares_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "func f() -> Int { a ?? b +++ c }"), [])
        XCTAssertEqual(try values(in: "func f() -> Int { o ??? n }"), [])
    }

    func test_aCoalescingOperatorPassedByName_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "func f() -> Int? { items.reduce(nil, ??) }"), [])
    }

    // Any `??` in the file may be the overload, whose fallback needn't be what it gives: `Binding<Int>` from `0`.
    func test_aCoalescingInAFileThatDeclaresACoalescingOperator_isLeftAlone() throws {
        let use = "func f(_ b: Binding<Int?>) -> Binding<Int> { b ?? 0 }"
        XCTAssertEqual(try values(in: """
        extension Binding {
            static func ?? <T>(lhs: Binding<T?>, rhs: T) -> Binding<T> { fatalError("unused") }
        }
        \(use)
        """), [])
        XCTAssertEqual(try values(in: """
        func ?? (lhs: Query, rhs: Int) -> Query { lhs }
        \(use)
        """), [])
        XCTAssertEqual(try values(in: use), ["b ?? 0"])
    }
}
