@testable import muterCore
import XCTest

/// ReplaceReturnValue replaces what a body returns with an empty value of its written return type.
final class ReplaceReturnValueOperatorTests: MuterTestCase {
    func visitor(walking code: String, coverage: FileCoverage = .empty) throws -> MuterVisitor {
        let source = try sourceCode(code)
        let visitor = ReplaceReturnValueOperator.Visitor(
            sourceCodeInfo: .init(path: "/path/to/file", code: source),
            coverage: coverage
        )
        visitor.walk(source)
        return visitor
    }

    /// The values replaced, in the order of the file.
    func values(in code: String) throws -> [String] {
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

    // Swift infers an opaque type from each value returned, and can't from an empty one, so a type with a `some`
    // anywhere in it gets no mutant, though `[T]`, `[K: V]` and `T?` do.
    func test_aTypeWithASomeInIt_getsNoMutant() throws {
        for type in [
            "[some Shape]", "[String: some Shape]", "(some Shape)?", "Optional<some Shape>", "Set<some Hashable>",
            "[[some Shape]]", "Swift.Array<some Shape>",
        ] {
            XCTAssertEqual(try values(in: "func f() -> \(type) { return load() }"), [], type)
        }
        XCTAssertEqual(try values(in: "func f() -> [any Shape] { return load() }"), ["load()"])
        XCTAssertEqual(try values(in: "func f() -> (any Shape)? { return load() }"), ["load()"])
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

    private func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
