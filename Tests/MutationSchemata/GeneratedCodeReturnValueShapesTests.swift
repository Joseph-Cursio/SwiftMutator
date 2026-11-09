@testable import muterCore
import XCTest

/// ReplaceReturnValue's shapes, compiled with the real compiler as `GeneratedCodeShapesTests` compiles the others'.
extension GeneratedCodeShapesTests {
    /// Each type and each place a return value is replaced: a function's `return` and one expression, a getter's, a
    /// `get` accessor's, a throwing getter's, a subscript's, a closure's, one called on the spot for a global's value,
    /// and a value touching `return`. All of them must compile together, each in a branch of its own, and each is
    /// switched on by itself.
    func test_theGeneratedCodeBuildsForReplacedReturnValues() throws {
        let code = """
        struct Store {
            var items: [Int]
            var byName: [String: Int] { Dictionary(uniqueKeysWithValues: items.map { ("n\\($0)", $0) }) }
            var first: Int? { items.first }
            var title: String { get { "store\\(items.count)" } }
            var total: Int { get throws { try sum(items) } }
            subscript(index: Int) -> Double { Double(items[index]) }
        }

        func sum(_ values: [Int]) throws -> Int { values.reduce(0, +) }

        func unique(_ values: [Int]) -> Set<Int> { Set(values) }

        func label(_ count: Int) -> Substring { "labels".prefix(count) }

        func small(_ value: Int) -> Int8 { Int8(value) }

        func ratio(_ value: Int) async -> Float { return Float(value) / 2 }

        func lookup(_ value: Int) -> Optional<String> { value > 0 ? "found" : nil }

        func noted(_ value: Int) -> UInt64 {
            return(UInt64(value) + 1)
        }

        func unwrapped(_ value: Int) -> Int! { value * 3 }

        func never(_ value: Int) -> Int { fatalError("never \\(value)") }

        func make(_ value: Int) -> [Int] {
            let doubled = { (item: Int) -> [Int] in [item, item] }
            let counted = [1, 2].map { (item: Int) -> Int in return item * value }
            // Read here too: a local only the replaced value reads is never used in its mutant, which warns.
            print(doubled(0).count, counted.count)
            return [doubled(value), counted].flatMap { $0 } // why
        }

        let globalNames: [String] = { () -> [String] in ["global"] }()
        """
        let main = driver("""
        let store = Store(items: [4, 5])
        print(store.byName.count, store.first as Any, store.title, try store.total, store[1])
        print(unique([1, 1]).count, label(2), small(7), await ratio(3), lookup(1) as Any, noted(1), unwrapped(2) as Any)
        print(make(2), globalNames)
        """)
        let compiled = try compileMutated(["Values.swift": code], plain: ["main.swift": main])

        let replaced = { (text: String) -> [String] in
            compiled.mutants(in: "Values.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .replaceReturnValue }.map(\.snapshot.after)
        }
        XCTAssertEqual(replaced("var byName"), ["[:]"], "a getter's dictionary")
        XCTAssertEqual(replaced("var first"), ["nil"], "a getter's optional")
        XCTAssertEqual(replaced("var title"), ["\"\""], "a get accessor's string")
        XCTAssertEqual(replaced("get throws"), ["0"], "a throwing getter's try")
        XCTAssertEqual(replaced("subscript"), ["0"], "a subscript's Double")
        XCTAssertEqual(replaced("func sum"), ["0"], "a function's one expression")
        XCTAssertEqual(replaced("func unique"), ["[]"], "a set")
        XCTAssertEqual(replaced("func label"), ["\"\""], "a substring")
        XCTAssertEqual(replaced("func small"), ["0"], "an Int8")
        XCTAssertEqual(replaced("func ratio"), ["0"], "an async function's return")
        XCTAssertEqual(replaced("func lookup"), ["nil"], "Optional<String>")
        XCTAssertEqual(replaced("return(UInt64"), ["0"], "a value touching return")
        XCTAssertEqual(replaced("func unwrapped"), ["nil"], "an implicitly unwrapped optional")
        XCTAssertEqual(replaced("func never"), ["0"], "a body that never returns")
        XCTAssertEqual(replaced("let doubled"), ["[]"], "a stored closure's one expression")
        XCTAssertEqual(replaced("let counted"), ["0"], "a return in a closure passed to a call")
        XCTAssertEqual(replaced("return [doubled"), ["[]"], "a return, and a comment")
        XCTAssertEqual(replaced("let globalNames"), ["[]"], "a closure called on the spot for a global's value")

        let first = "2 Optional(4) store2 9 5.0\n1 la 7 1.5 Optional(\"found\") 2 Optional(6)\n"
        XCTAssertEqual(
            try run(compiled.program).output,
            first + "2 2\n[2, 2, 2, 4] [\"global\"]\n",
            "no mutant named"
        )
        for (before, output) in [
            ("[doubled(value), counted].flatMap { $0 }", "2 2\n[]"),
            ("[item, item]", "0 2\n[2, 4]"),
            ("item * value", "2 2\n[2, 2, 0, 0]"),
        ] {
            let id = try compiled.identifier(in: "Values.swift") {
                $0.mutationOperatorId == .replaceReturnValue && $0.snapshot.before == before
            }
            XCTAssertEqual(
                try run(compiled.program, switchingOn: id).output,
                first + output + " [\"global\"]\n",
                before
            )
        }
        let global = try compiled.identifier(in: "Values.swift") {
            $0.mutationOperatorId == .replaceReturnValue && $0.snapshot.before == "[\"global\"]"
        }
        XCTAssertEqual(try run(compiled.program, switchingOn: global).output, first + "2 2\n[2, 2, 2, 4] []\n")
    }

    /// A result builder would take an empty value as a component, which it can't build, so the one expression of a
    /// body a builder may build is left alone: a function, property or subscript with an attribute that may be a
    /// builder, a closure passed to a call, and a member a protocol's requirement gives its builder. A `return` turns
    /// a builder off, so a closure's is replaced; a function's or property's would make the compiler warn already.
    func test_theGeneratedCodeBuildsForReturnValuesInAResultBuilder() throws {
        let code = """
        @resultBuilder enum Lines {
            static func buildExpression(_ line: String) -> [String] { [line] }
            static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }
        }

        func lines(@Lines _ make: () -> [String]) -> [String] { make() }

        protocol Report {
            @Lines var body: [String] { get }
        }

        struct Daily: Report {
            var count: Int
            var body: [String] { String(count) }
            @Lines var header: [String] { "header" }
            @Lines subscript(index: Int) -> [String] { String(index) }
            @Lines func footer() -> [String] { "footer" }
            @discardableResult func plain() -> [String] { [String(count)] }
            func passed() -> [String] { lines { () -> [String] in "passed" } }
            func returned() -> [String] { lines { () -> [String] in return ["returned"] } }
        }
        """
        let main = driver("""
        let daily = Daily(count: 1)
        print(daily.body, daily.header, daily[2], daily.footer(), daily.plain(), daily.passed(), daily.returned())
        """)
        let compiled = try compileMutated(["Builders.swift": code], plain: ["main.swift": main])

        let replaced = { (text: String) -> [String] in
            compiled.mutants(in: "Builders.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .replaceReturnValue }.map(\.snapshot.before)
        }
        XCTAssertEqual(replaced("var body: [String] { String"), [], "a member a requirement gives its builder")
        XCTAssertEqual(replaced("var header"), [], "a property with a builder")
        XCTAssertEqual(replaced("subscript"), [], "a subscript with a builder")
        XCTAssertEqual(replaced("func footer"), [], "a function with a builder")
        XCTAssertEqual(
            replaced("func passed"),
            ["lines { () -> [String] in \"passed\" }"],
            "a closure passed to a call, but the function's own"
        )
        XCTAssertEqual(
            replaced("func returned"),
            ["lines { () -> [String] in return [\"returned\"] }", "[\"returned\"]"],
            "a closure's return"
        )
        XCTAssertEqual(replaced("func plain"), ["[String(count)]"], "an attribute known not to be a builder")
        XCTAssertEqual(replaced("static func buildExpression"), ["[line]"], "the builder's own function")
        XCTAssertEqual(replaced("func lines"), ["make()"], "a function a builder's closure is passed to")

        let output = "[\"1\"] [\"header\"] [\"2\"] [\"footer\"] [\"1\"] [\"passed\"] [\"returned\"]\n"
        XCTAssertEqual(try run(compiled.program).output, output, "no mutant named")
        let id = try compiled.identifier(in: "Builders.swift") {
            $0.mutationOperatorId == .replaceReturnValue && $0.snapshot.before == "[\"returned\"]"
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: id).output,
            output.replacingOccurrences(of: "[\"returned\"]", with: "[]")
        )
    }

    /// A type the file declares under a standard library name may not take the empty value, so a return type that
    /// names it gets no mutant, nor does one that names a generic parameter of that name. `Swift.` names the standard
    /// library's.
    func test_theGeneratedCodeBuildsWhereTheFileDeclaresAStandardLibraryName() throws {
        let code = """
        enum Units {
            struct Double {
                let value: Swift.Double
            }

            static func half() -> Double { Double(value: 0.5) }
            static func whole() -> Swift.Double { 1.5 }
        }

        func pick<String>(_ value: String) -> String { value }
        """
        let compiled = try compileMutated(
            ["Units.swift": code],
            plain: ["main.swift": driver(#"print(Units.half().value, Units.whole(), pick("a"))"#)]
        )

        let replaced = { (text: String) -> [String] in
            compiled.mutants(in: "Units.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .replaceReturnValue }.map(\.snapshot.after)
        }
        XCTAssertEqual(replaced("func half"), [], "a type the file declares")
        XCTAssertEqual(replaced("func whole"), ["0"], "the standard library's, by the module's name")
        XCTAssertEqual(replaced("func pick"), [], "a generic parameter")
        XCTAssertEqual(try run(compiled.program).output, "0.5 1.5 a\n")
    }

    /// Without its `try`, a closure written to return a value no longer throws, and `map`, which rethrows, leaves the
    /// global's own `try!` over nothing that throws, which warns. A global's value is switched whole, so the copy with
    /// the mutant holds that `try`. So a closure's value with a `try` or `await` is left alone, though a function's is
    /// replaced.
    func test_theGeneratedCodeBuildsForAClosuresValueWithATry() throws {
        let code = """
        func load(_ value: Int) throws -> [Int] { [value] }

        let loaded = try! [1, 2].map { (item: Int) -> [Int] in try load(item) }

        func loadAll() throws -> [Int] { try load(3) }
        """
        let compiled = try compileMutated(
            ["Loads.swift": code],
            plain: ["main.swift": driver("print(loaded, try loadAll())")]
        )

        let replaced = { (text: String) -> Int in
            compiled.mutants(in: "Loads.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .replaceReturnValue }.count
        }
        XCTAssertEqual(replaced("let loaded"), 0, "a closure's value with a try")
        XCTAssertEqual(replaced("func loadAll"), 1, "a function's value with a try")
        XCTAssertEqual(replaced("func load("), 1, "a function's value")
        XCTAssertEqual(try run(compiled.program).output, "[[1], [2]] [3]\n")
    }
}
