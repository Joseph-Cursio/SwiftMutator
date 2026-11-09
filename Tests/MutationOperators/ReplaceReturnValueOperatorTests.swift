@testable import muterCore
import XCTest

/// ReplaceReturnValue replaces what a body returns with an empty value of its written return type.
final class ReplaceReturnValueOperatorTests: MuterTestCase {
    private func visitor(walking code: String, coverage: FileCoverage = .empty) throws -> MuterVisitor {
        let source = try sourceCode(code)
        let visitor = ReplaceReturnValueOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.walk(source)
        return visitor
    }

    /// The values replaced, in the order of the file.
    private func values(in code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata.map(\.snapshot.before)
    }

    /// What each value is replaced with, in the order of the file.
    private func replacements(in code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata.map(\.snapshot.after)
    }

    /// What each mutant makes of its statement list, in the order of the file, its spacing collapsed.
    private func mutants(of code: String) throws -> [String] {
        try visitor(walking: code).schemataMappings.mutationSchemata
            .map { collapsingWhitespace($0.syntaxMutation.description) }
    }

    func test_aReturnedArray_becomesEmpty() throws {
        XCTAssertEqual(try mutants(of: "func f() -> [Int] { return items.sorted() }"), ["return []"])
    }

    // One mutant, placed where the value starts, after its leading trivia.
    func test_theMutant_isPlacedWhereTheValueStarts_andItsSnapshotNamesTheValue() throws {
        let schemata = try visitor(walking: """
        func f() -> [Int] {
            return items.sorted()
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.mutationOperatorId), [.replaceReturnValue])
        XCTAssertEqual(schemata.map(\.position.line), [2])
        XCTAssertEqual(schemata.map(\.position.column), [12])
        XCTAssertEqual(schemata.map(\.snapshot), [
            .init(before: "items.sorted()", after: "[]", description: "replaced the return value with []"),
        ])
    }

    // MARK: The empty value of each type written

    func test_eachTypeWritten_getsItsEmptyValue() throws {
        let table: [(type: String, empty: String)] = [
            ("Int?", "nil"), ("Item!", "nil"), ("Optional<Item>", "nil"), ("Swift.Optional<Int>", "nil"),
            ("[Int]?", "nil"), ("String?", "nil"), ("Bool?", "nil"), ("[String: Int]?", "nil"), ("(Int)?", "nil"),
            ("[Int]", "[]"), ("Array<Int>", "[]"), ("Set<String>", "[]"), ("Swift.Array<Int>", "[]"),
            ("Swift.Set<Int>", "[]"), ("[[String: Int]]", "[]"), ("[(Int, Int)]", "[]"),
            ("[String: Int]", "[:]"), ("Dictionary<String, Int>", "[:]"), ("[String: [Int]]", "[:]"),
            ("[[Int]: String]", "[:]"), ("Swift.Dictionary<String, Int>", "[:]"),
            ("String", "\"\""), ("Substring", "\"\""), ("Swift.String", "\"\""),
            ("Int", "0"), ("Int8", "0"), ("Int16", "0"), ("Int32", "0"), ("Int64", "0"), ("UInt", "0"),
            ("UInt8", "0"), ("UInt16", "0"), ("UInt32", "0"), ("UInt64", "0"), ("Double", "0"), ("Float", "0"),
            ("CGFloat", "0"), ("Swift.Int", "0"), ("(Int)", "0"), ("((String))", "\"\""), ("[ Int ]", "[]"),
        ]
        for (type, empty) in table {
            XCTAssertEqual(try replacements(in: "func f() -> \(type) { load() }"), [empty], type)
        }
    }

    // The tree has no types, so a type that isn't written in one of the table's forms gets no mutant. A Bool is
    // ReplaceBooleanValue's.
    func test_aTypeWrittenInAnyOtherWay_getsNoMutant() throws {
        for type in [
            "Bool", "Swift.Bool", "some Collection", "any Sequence", "Item", "T", "Self", "(Int, Int)", "() -> Int",
            "(Int) -> Int?", "(Int) -> [Int]", "Result<Int, Error>", "ContiguousArray<Int>", "Int.Type",
            "Character", "Decimal", "Array<Int, Int>", "Optional", "Foundation.Data", "MyModule.Int",
        ] {
            XCTAssertEqual(try values(in: "func f() -> \(type) { load() }"), [], type)
        }
        XCTAssertEqual(try values(in: "typealias Count = Int; func f() -> Count { load() }"), [])
        XCTAssertEqual(try values(in: "func f<T>() -> T { load() }"), [])
    }

    // A type the file declares under a standard library name is that type, which may not take the empty value. The
    // module's name, or the sugar of `[T]` and `T?`, still names the standard library's.
    func test_aNameTheFileDeclaresItself_getsNoMutant() throws {
        for declaration in [
            "struct Int {}", "class String {}", "enum Double {}", "actor Float {}", "typealias Int = Int32",
            "protocol Set {}", "struct S { struct String {} }", "func g<Int>(_ x: Int) {}",
            "protocol P { associatedtype Int }", "struct `String` {}",
        ] {
            let code = "\(declaration)\nfunc f() -> Int { load() }\nfunc g() -> String { load() }\n"
                + "func h() -> Double { load() }\nfunc i() -> Float { load() }\nfunc j() -> Set<Int> { load() }"
            XCTAssertEqual(try values(in: code).count, 4, declaration)
        }
        XCTAssertEqual(
            try replacements(in: """
            struct Int {}
            struct Array {}
            func f() -> Swift.Int { load() }
            func g() -> [Int] { load() }
            func h() -> Int? { load() }
            func i() -> Array<Item> { load() }
            """),
            ["0", "[]", "nil"]
        )
    }

    // MARK: Where it applies

    func test_whatAFunctionReturns_isReplaced() throws {
        XCTAssertEqual(try values(in: "func f() -> [Int] { return load() }"), ["load()"])
        XCTAssertEqual(try values(in: "func f() -> [Int] { load() }"), ["load()"])
        XCTAssertEqual(
            try values(in: "func f() -> String { if a { return first }; return second }"),
            ["first", "second"]
        )
        XCTAssertEqual(try values(in: "func f() -> Int { switch a { case 1: return b; default: return c } }"), [
            "b", "c",
        ])
    }

    func test_whatAGetterOrSubscriptReturns_isReplaced() throws {
        XCTAssertEqual(try values(in: "struct S { var name: String { first + last } }"), ["first + last"])
        XCTAssertEqual(try values(in: "struct S { var name: String { return first } }"), ["first"])
        XCTAssertEqual(
            try values(in: "struct S { var name: String { get { first } set { first = newValue } } }"),
            ["first"]
        )
        XCTAssertEqual(try values(in: "struct S { var count: Int { get throws { try load() } } }"), ["try load()"])
        XCTAssertEqual(try values(in: "struct S { subscript(i: Int) -> Item? { items[i] } }"), ["items[i]"])
        XCTAssertEqual(
            try values(in: "struct S { subscript(i: Int) -> [Int] { get { return rows[i] } } }"),
            ["rows[i]"]
        )
        XCTAssertEqual(try values(in: "var total: Double { load() }"), ["load()"], "a global")
    }

    func test_whatAClosureWritingItsReturnTypeReturns_isReplaced() throws {
        XCTAssertEqual(try values(in: "let f = { (x: Int) -> [Int] in [x] }"), ["[x]"])
        XCTAssertEqual(try values(in: "let f = { (x: Int) -> String in return name(x) }"), ["name(x)"])
        XCTAssertEqual(try values(in: "func f() { items.map { x -> Int in return x * 2 } }"), ["x * 2"])
        XCTAssertEqual(try values(in: "let n: Int = { () -> Int in count }()"), ["count"], "called on the spot")
    }

    // A `return` is the innermost closure's or function's, whatever is around it.
    func test_aReturnInANestedClosureOrFunction_isItsOwn() throws {
        XCTAssertEqual(
            try values(in: """
            func f() -> [Int] {
                let found = items.first { item in
                    return item.isReady
                }
                func count() -> Int { return items.count }
                return [count()]
            }
            """),
            ["items.count", "[count()]"]
        )
    }

    // MARK: What is left out

    // Initial values are ReplaceBooleanValue's sites, not this operator's.
    func test_aBindingsInitialValue_isLeftAlone() throws {
        for code in [
            "func f() { let x: [Int] = load() }",
            "func f() { var name: String = load() }",
            "struct S { var count: Int = load() }",
            "let total: Double = load()",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    func test_aClosureThatDoesntWriteItsReturnType_isLeftAlone() throws {
        for code in [
            "func f() { items.map { $0 * 2 } }",
            "func f() { items.map { x in x * 2 } }",
            "func f() { items.map { x in return x * 2 } }",
            "func f() -> [Int] { items.map { x in return x * 2 }.sorted() }",
        ] {
            XCTAssertEqual(try values(in: code).filter { !$0.hasPrefix("items") }, [], code)
        }
    }

    // Neither an `if` or `switch` expression, nor a branch's value, is replaced. A `return` inside an `if` or `switch`
    // statement is.
    func test_anIfOrSwitchExpression_andItsBranches_areLeftAlone() throws {
        for code in [
            "func f() -> Int { if a { b } else { c } }",
            "func f() -> String { return switch a { case 1: b; default: c } }",
            "struct S { var x: [Int] { if a { b } else { c } } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    func test_whatReturnsNothing_isLeftAlone() throws {
        for code in [
            "struct S { init?() { if a { return nil }; return } }",
            "func f() { return }",
            "func f() { load() }",
            "struct S { var x: Int { get { 1 + y } set { y = newValue + 1 } } }",
            "struct S { var x: Int = 1 { didSet { if x > 1 { return } } } }",
        ] {
            XCTAssertEqual(try values(in: code).filter { $0 != "1 + y" }, [], code)
        }
    }

    // `try?` makes an optional, which is left alone, as ReplaceBooleanValue leaves it.
    func test_aValueUnderTryQuestionMark_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "func f() -> Int? { try? load() }"), [])
        XCTAssertEqual(try values(in: "func f() -> [Int]? { return (try? load()) }"), [])
        XCTAssertEqual(try values(in: "func f() throws -> Int { try load() }"), ["try load()"])
        XCTAssertEqual(try values(in: "func f() -> Int { try! load() }"), ["try! load()"])
    }

    // That mutant would change nothing.
    func test_aValueThatAlreadyIsTheEmptyOne_isLeftAlone() throws {
        for code in [
            "func f() -> Int? { return nil }",
            "func f() -> Item! { nil }",
            "func f() -> Optional<Int> { (nil) }",
            "func f() -> [Int] { return [] }",
            "func f() -> Set<Int> { [] }",
            "func f() -> [String: Int] { return [:] }",
            "func f() -> String { return \"\" }",
            "func f() -> Substring { (\"\") }",
            "func f() -> String { #\"\"# }",
            "func f() -> String { \"\"\"\n\"\"\" }",
            "func f() -> Int { return 0 }",
            "func f() -> Int { 0_0 }",
            "func f() -> Int { 0x0 }",
            "func f() -> Int { 0b00 }",
            "func f() -> Int { -0 }",
            "func f() -> Double { 0.0 }",
            "func f() -> Double { 0e10 }",
            "func f() -> Double { 0x0p1 }",
            "func f() -> Float { (0.000) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        for code in [
            "func f() -> Int { 1 }",
            "func f() -> Int { 10 }",
            "func f() -> Double { 0.5 }",
            "func f() -> Double { 1e0 }",
            "func f() -> Int { 0x10 }",
            "func f() -> String { \"a\" }",
            "func f() -> String { \"\\(a)\" }",
            "func f() -> [Int] { [0] }",
            "func f() -> [Int: Int] { [0: 0] }",
            "func f() -> Int? { 0 }",
            "func f() -> [Int]? { [] }",
            "func f() -> String? { \"\" }",
        ] {
            XCTAssertEqual(try values(in: code).count, 1, code)
        }
    }

    // MARK: Result builders

    // A builder would take the empty value as a component, which it may not build. The tree can't tell which
    // attribute is a builder, so any but those known not to be one leaves out a body's one expression; a `return`
    // turns a builder off, so its value is kept.
    func test_theOneExpressionOfABodyAResultBuilderMayBuild_isLeftAlone() throws {
        for code in [
            "@Lines func f() -> [String] { load() }",
            "struct S { @Lines var x: [String] { load() } }",
            "struct S { var x: [String] { @Lines get { load() } } }",
            "struct S { @Lines subscript(i: Int) -> [String] { load() } }",
            "@Lines @inlinable func f() -> String { load() }",
            "#if DEBUG\n@inlinable\n#endif\nfunc f() -> String { load() }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try values(in: "@Lines func f() -> [String] { return load() }"), ["load()"])
        XCTAssertEqual(try values(in: "struct S { @Lines var x: [String] { return load() } }"), ["load()"])
    }

    func test_anAttributeKnownNotToBeABuilder_keepsTheValue() throws {
        for attribute in [
            "@inlinable", "@inline(__always)", "@discardableResult", "@available(macOS 14, *)", "@objc",
            "@nonobjc", "@usableFromInline", "@MainActor", "@preconcurrency", "@_spi(Testing)",
            "@backDeployed(before: macOS 15)", "@warn_unqualified_access", "@_disfavoredOverload", "@_transparent",
            "@_alwaysEmitIntoClient",
        ] {
            XCTAssertEqual(try values(in: "\(attribute) func f() -> Int { load() }"), ["load()"], attribute)
        }
        XCTAssertEqual(try values(in: "struct S { @MainActor var x: Int { load() } }"), ["load()"])
    }

    // A closure passed to a call may be built by a builder its parameter is declared with, which may be in another
    // file. One stored, or called on the spot, isn't.
    func test_theOneExpressionOfAClosurePassedToACall_isLeftAlone() throws {
        for code in [
            "func f() { lines { () -> [String] in load() } }",
            "func f() { lines(make: { () -> [String] in load() }) }",
            "func f() { lines { () -> [String] in load() } footer: { () -> [String] in load() } }",
            "func f() { x[{ () -> Int in load() }] }",
            "func f() { #lines({ () -> [String] in load() }) }",
            "let f = { @Lines () -> [String] in load() }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try values(in: "func f() { lines { () -> [String] in return load() } }"), ["load()"])
        XCTAssertEqual(try values(in: "let f = { @MainActor () -> [String] in load() }"), ["load()"])
    }

    // Swift gives a protocol's requirement's builder to the member that meets it, which carries no attribute of its
    // own. A protocol declared in another file isn't seen.
    func test_aMemberNamedAsARequirementWithABuilder_isLeftAlone() throws {
        XCTAssertEqual(
            try values(in: """
            protocol Report {
                @Lines var lines: [String] { get }
                @Lines func footer() -> [String]
                @MainActor var title: String { get }
            }
            struct Daily: Report {
                var lines: [String] { load() }
                func footer() -> [String] { load() }
                var title: String { name }
                var other: [String] { rows }
            }
            """),
            ["name", "rows"]
        )
    }

    // MARK: A closure's try and await

    // Without its `try` or `await`, a closure may no longer throw or wait, and a call it is passed to that rethrows
    // leaves its own `try` over nothing that throws, which warns.
    func test_aClosuresValueWithATryOrAwait_isLeftAlone() throws {
        for code in [
            "let f = { (x: Int) -> [Int] in return try load(x) }",
            "let f = { (x: Int) async -> Int in return await load(x) }",
            "let f = { (x: Int) -> [Int] in return [try load(x)] }",
            "let f = { (x: Int) -> [Int] in return (x > 1 ? try load(x) : []) }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        // A nested closure's are its own, and a function's are fine.
        XCTAssertEqual(
            try values(in: "let f = { (x: Int) -> Int in return run { try load(x) } }"),
            ["run { try load(x) }"]
        )
        XCTAssertEqual(try values(in: "func f() async throws -> [Int] { try await load() }"), ["try await load()"])
    }

    // MARK: How the value is replaced

    // A comment beside the value stays where it was, and a comment after it can't take in what follows.
    func test_theTriviaAroundTheValue_isKept() throws {
        XCTAssertEqual(
            try mutants(of: """
            func f() -> [Int] {
                return /* why */ items.sorted() // because
            }
            """),
            ["return /* why */ [] // because"]
        )
    }

    func test_aValueOverSeveralLines_isReplacedWhole_andGivenOnOneLine() throws {
        let schemata = try visitor(walking: """
        func f() -> String {
            return first +
                // the second
                second
        }
        """).schemataMappings.mutationSchemata

        XCTAssertEqual(schemata.map(\.snapshot.before), ["first + // the second second"])
        XCTAssertEqual(schemata.map { collapsingWhitespace($0.syntaxMutation.description) }, ["return \"\""])
        XCTAssertEqual(schemata.map(\.position.line), [2])
    }

    // `return(x)` would otherwise become `return0`.
    func test_aValueTouchingAKeyword_isKeptApartFromIt() throws {
        XCTAssertEqual(try mutants(of: "func f() -> Int { return(x) }"), ["return 0"])
        XCTAssertEqual(try mutants(of: "func f() -> Int? { return(x) }"), ["return nil"])
        XCTAssertEqual(try mutants(of: "func f() -> [Int] { return(x) }"), ["return []"])
    }

    // MARK: Where the shared rules apply

    func test_aDisableTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable
            if a { return b }
            // muter:enable
            return c
        }
        """), ["c"])
    }

    // The tag can sit beside the value itself, so it has to be read before the value is.
    func test_aDisableTagBesideTheValue_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            return
                // muter:disable
                count
        }
        """), [])
    }

    func test_aDisableNextLineTag_isRead() throws {
        XCTAssertEqual(try values(in: """
        func f() -> Int {
            // muter:disable-next-line
            if a { return b }
            return c
        }
        """), ["c"])
    }

    func test_aValueInACompilerDirectivesCode_isReplaced() throws {
        XCTAssertEqual(try values(in: """
        func f() -> String {
            #if DEBUG
            return debugName
            #else
            return name
            #endif
        }
        """), ["debugName", "name"])
    }

    // As with any other operator, code the tests never ran gets no mutant.
    func test_codeThatNeverRan_isLeftOut() throws {
        let visitor = try visitor(
            walking: """
            func f() -> Int {
                if a {
                    return b
                }
                return c
            }
            """,
            coverage: .make(regionsWithoutCoverage: [.make(lineStart: 2, columnStart: 10, lineEnd: 4, columnEnd: 6)])
        )

        XCTAssertEqual(visitor.schemataMappings.mutationSchemata.map(\.position.line), [5])
    }

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
