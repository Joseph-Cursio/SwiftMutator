@testable import muterCore
import XCTest

extension GeneratedCodeShapesTests {
    /// The arithmetic and literal mutants that have nowhere but a value to go, as well as those in statements, and a
    /// `+` beside what shows it holds numbers. All of them must compile together, each in a branch of its own.
    func test_theGeneratedCodeBuildsForArithmeticAndLiterals() throws {
        let code = Self.arithmeticAndLiteralsCode
        let compiled = try compileMutated(["Shapes.swift": code])

        let mutants = { compiled.operators(in: "Shapes.swift", onTheLineHolding: $0) }
        XCTAssertEqual(mutants("var isOn"), [.flipBooleanLiteral], "a stored property")
        XCTAssertEqual(mutants("var limit"), [.arithmeticOperator], "a stored property's calculation")
        XCTAssertEqual(mutants("static let threshold"), [.arithmeticOperator], "a static property")
        XCTAssertEqual(mutants("lazy var"), [.flipBooleanLiteral], "a lazy property")
        XCTAssertEqual(mutants("func scaled"), [.arithmeticOperator, .flipBooleanLiteral], "default arguments")
        XCTAssertEqual(mutants("let isGlobal"), [.flipBooleanLiteral], "a global")
        XCTAssertEqual(mutants("var counter ="), [.arithmeticOperator], "a global's calculation")
        XCTAssertEqual(mutants("total += 1"), [.arithmeticOperator], "an assignment form")
        XCTAssertEqual(mutants("return total +"), [.arithmeticOperator, .replaceReturnValue], "a count")
        XCTAssertEqual(
            mutants("case true:"),
            [.ror, .flipBooleanLiteral],
            "what a case runs, but not its pattern"
        )
        XCTAssertEqual(mutants("while true"), [], "a whole condition")
        XCTAssertEqual(mutants("if true { return 1 }"), [.replaceReturnValue], "a whole condition, but not its value")
        XCTAssertEqual(mutants("#if true"), [], "a directive's condition")
        XCTAssertEqual(mutants("var result"), [], "a + of strings")
        XCTAssertEqual(mutants("result += name"), [], "a += of strings")
        XCTAssertEqual(mutants("let compiled"), [.flipBooleanLiteral], "a directive's code")
    }

    private static let arithmeticAndLiteralsCode = """
    struct Settings {
        var isOn = true
        var limit = 2 * 3
        static let threshold = 10 - 4
        lazy var isLazy = false
        func scaled(by factor: Int = 4 / 2, isExact: Bool = false) -> Int {
            isExact ? limit : limit * factor
        }
    }

    let isGlobal = false
    nonisolated(unsafe) var counter = 7 % 4

    func count(_ items: [Int]) -> Int {
        var total = 0
        for item in items {
            total += 1
            total -= item
        }
        total *= 2
        total /= 2
        total %= 100
        return total + items.count
    }

    func flags(_ value: Bool) -> (Bool, Bool) {
        switch value {
        case true: return (true, value == false)
        case false: return (false, value == true)
        }
    }

    func loop() -> Int {
        while true {
            if counter > 0 { return counter }
            counter += 1
        }
    }

    func branch() -> Int {
        if true { return 1 }
    }

    func text(_ name: String, _ more: [Int]) -> String {
        var result = name + "!"
        result += name
        return result + String(more.count + 1) + name
    }

    #if true
    let compiled = false
    #endif
    """

    /// Each place a Bool value is replaced: a value with `try` or `await` in it, a `let` read later, a getter's,
    /// a subscript's and a closure's one expression, and the values that have no statement list. All of them must
    /// compile together, each in a branch of its own, and each of a value's two mutants is switched on by itself.
    func test_theGeneratedCodeBuildsForReplacedBooleanValues() throws {
        let code = Self.replacedBooleanValuesCode
        let main = driver("""
        var flags = Flags(count: 2)
        print(flags.isLarge, Flags.isDebug, flags.isLazy, flags.isEmpty, flags.isSmall, try flags.isLoaded, flags[1])
        print(isGlobal, try await check([1, 2]), noted(0), noted(2))
        """)
        let compiled = try compileMutated(["Values.swift": code], plain: ["main.swift": main])

        let replaced = { (text: String) -> Int in
            compiled.mutants(in: "Values.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .replaceBooleanValue }.count
        }
        XCTAssertEqual(replaced("var isLarge"), 2, "a stored property")
        XCTAssertEqual(replaced("static let isDebug"), 2, "a static property written as Bool")
        XCTAssertEqual(replaced("lazy var"), 2, "a lazy property")
        XCTAssertEqual(replaced("var isEmpty"), 2, "a getter's one expression")
        XCTAssertEqual(replaced("var isSmall"), 2, "a get accessor's return")
        XCTAssertEqual(replaced("get throws"), 2, "a throwing getter's try")
        XCTAssertEqual(replaced("subscript"), 2, "a subscript")
        XCTAssertEqual(replaced("let isGlobal"), 2, "a global")
        XCTAssertEqual(replaced("func load"), 2, "a function's one expression")
        XCTAssertEqual(replaced("let isLoaded"), 2, "a let with try, read later")
        XCTAssertEqual(replaced("let isFetched"), 2, "a let with await, read later")
        XCTAssertEqual(replaced("let isLarge = {"), 2, "a closure that writes its return type")
        XCTAssertEqual(replaced("return try await"), 2, "a return with try and await, and a comment")
        XCTAssertEqual(replaced("return(value"), 2, "a value touching return")
        XCTAssertEqual(replaced("print("), 0, "an argument")

        let first = "false false true false true true true\nfalse false 1\n"
        XCTAssertEqual(try run(compiled.program).output, first + "true true false true\n", "no mutant named")
        // Each of the pair is switched on by itself: `noted(0)` and `noted(2)` give each value.
        for (after, output) in [("true", "true true true true\n"), ("false", "true true false false\n")] {
            let id = try compiled.identifier(in: "Values.swift") {
                $0.mutationOperatorId == .replaceBooleanValue && $0.snapshot.before == "(value > 1)"
                    && $0.snapshot.after == after
            }
            XCTAssertEqual(try run(compiled.program, switchingOn: id).output, first + output, after)
        }
    }

    private static let replacedBooleanValuesCode = """
    struct Flags {
        var count: Int
        var isLarge = CommandLine.arguments.count > 5
        static let isDebug: Bool = CommandLine.arguments.contains("--debug")
        lazy var isLazy = !CommandLine.arguments.isEmpty
        var isEmpty: Bool { count == 0 }
        var isSmall: Bool { get { return count < 3 } }
        var isLoaded: Bool { get throws { try load(count) } }
        subscript(index: Int) -> Bool { index < count }
    }

    let isGlobal = CommandLine.arguments.count < 100

    func load(_ count: Int) throws -> Bool { count >= 0 }

    func fetch(_ count: Int) async -> Bool { count != 7 }

    func check(_ items: [Int]) async throws -> Bool {
        let isLoaded = try load(items.count) && items.isEmpty
        let isFetched = !(await fetch(items.count))
        let isLarge = { (item: Int) -> Bool in item > 1 }
        print(isLoaded, isFetched, items.filter(isLarge).count)
        return try await fetch(items.count) == load(1) // why
    }

    func noted(_ value: Int) -> Bool {
        return(value > 1)
    }
    """

    /// An `if` in a closure on the left of a `??` settles the `??` before the closure is read, so a closure that gives
    /// an optional doesn't compile, with nothing around to name the type: "value of optional type 'String?' must be
    /// unwrapped to a value of type 'String'". Whatever the operator. So the switch goes around the statement, or the
    /// value at a file's or a type's top level, and the closure stays as it was. Seen on SwiftProjectLint.
    func test_theGeneratedCodeBuildsInAClosureOnTheLeftOfACoalescing() throws {
        leftOutOperators = [.replaceReturnValue]
        let paths = Self.closureLeftOfCoalescingCode
        let main = driver(#"""
        let results: [String?] = [
            global, Holder().stored, defaulted(), arithmetic(1), comparison(1), logical(1, true), returned(1),
            chained(1), parenthesized(1), nested(1) ?? "gone", local(1),
        ]
        print(results.map { $0 ?? "nil" }.joined(separator: ","))
        """#)
        let compiled = try compileMutated(["Paths.swift": paths], plain: ["main.swift": main])

        let mutants = { compiled.operators(in: "Paths.swift", onTheLineHolding: $0) }
        XCTAssertEqual(mutants("let found ="), [.arithmeticOperator], "an arithmetic operator")
        XCTAssertEqual(mutants("look(if: $0 > 0)"), [.ror, .relationalBoundary], "a comparison")
        XCTAssertEqual(mutants("look(if: other"), [.ror, .logicalOperator], "a logical operator")
        XCTAssertEqual(mutants("return look($0 * 2)"), [.arithmeticOperator], "a closure's return")
        XCTAssertEqual(mutants("look($0 - -1)"), [.arithmeticOperator], "a chain")
        XCTAssertEqual(mutants("(key.map"), [.arithmeticOperator], "parentheses")
        XCTAssertEqual(mutants("Optional($0).map"), [.arithmeticOperator], "a closure in that closure")
        XCTAssertEqual(mutants("let global"), [.arithmeticOperator], "a global's value")
        XCTAssertEqual(mutants("func defaulted"), [.arithmeticOperator], "a default argument")
        XCTAssertEqual(mutants("func given"), [.arithmeticOperator], "a local function's default argument")

        let everything = Array(repeating: "found", count: 11).joined(separator: ",")
        XCTAssertEqual(try run(compiled.program).output, everything + "\n", "no mutant named")

        let arithmetic = try XCTUnwrap(compiled.mutants(in: "Paths.swift", onTheLineHolding: "let found =").first)
        XCTAssertEqual(
            try run(compiled.program, switchingOn: arithmetic.id).output.components(separatedBy: ",")[3],
            "nil",
            "the arithmetic mutant's change"
        )
    }

    private static let closureLeftOfCoalescingCode = """
    func look(_ key: Int) -> String? { key == 2 ? "found" : nil }
    func look(if isFound: Bool) -> String? { isFound ? "found" : nil }

    let global = Optional(1).map { look($0 + 1) } ?? "none"

    struct Holder {
        let stored = Optional(1).map { look($0 + 1) } ?? "none"
    }

    func defaulted(_ value: String? = Optional(1).map { look($0 + 1) } ?? "none") -> String? { value }

    func arithmetic(_ key: Int?) -> String? {
        let found = key.map { look($0 + 1) } ?? "none"
        guard let found else { return nil }
        return found
    }

    func comparison(_ key: Int?) -> String? {
        let base = key.map { look(if: $0 > 0) } ?? "none"
        return base
    }

    func logical(_ key: Int?, _ other: Bool) -> String? {
        let base = key.map { look(if: other && $0 != 9) } ?? "none"
        return base
    }

    func returned(_ key: Int?) -> String? {
        let base = key.map { return look($0 * 2) } ?? "none"
        return base
    }

    func chained(_ key: Int?) -> String? {
        let base = key.map { look($0 - -1) }.map { $0 } ?? "none"
        return base
    }

    func parenthesized(_ key: Int?) -> String? {
        let base = (key.map { look($0 + 1) }) ?? "none"
        return base
    }

    func nested(_ key: Int?) -> String?? {
        let base = key.map { Optional($0).map { look($0 + 1) } } ?? "none"
        return base
    }

    func local(_ key: Int?) -> String? {
        struct Inner {
            let stored = Optional(1).map { look($0 + 1) } ?? "none"
        }
        func given(_ value: String? = Optional(1).map { look($0 + 1) } ?? "none") -> String? { value }
        return Inner().stored ?? given()
    }
    """
}
