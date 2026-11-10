@testable import muterCore
import XCTest

extension GeneratedCodeShapesTests {
    /// Each shape of a comparison RelationalOperatorReplacement mutates: the swap of an ordering comparison, and the
    /// constant in place of the comparison as the standard table folds it, with `try` and `await` in it, inside more
    /// of a sequence, in a condition, a ternary, a getter, a subscript, a closure and the values that have no statement
    /// list; and the swap alone, of a comparison that is a statement, one in a sequence the standard table can't fold
    /// and one that holds a closure's only `$0`; and a loop's condition, without the `true` that would keep it going.
    /// All of them must compile together, each in a branch of its own, and the swap and each constant are switched on
    /// by themselves.
    func test_theGeneratedCodeBuildsForComparisonsSwapsAndConstants() throws {
        leftOutOperators = [.replaceReturnValue]
        let code = Self.comparisonsCode
        let main = driver("""
        let limits = Limits(count: 2)
        print(limits.isFull, Limits.isDebug, limits.isEmpty, limits[1], isGlobal)
        print(try await check([1, 2]))
        print(ordered(0), ordered(2), same(2), same(3))
        """)
        let compiled = try compileMutated(["Comparisons.swift": code], plain: ["main.swift": main])

        let changes = { (text: String) -> [String] in
            compiled.mutants(in: "Comparisons.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .ror }
                .map { "\($0.snapshot.before) → \($0.snapshot.after)" }
        }
        XCTAssertEqual(
            changes("var isFull"), ["CommandLine.arguments.count >= 5 → true", ">= → =="], "a stored property"
        )
        XCTAssertEqual(changes("static let isDebug").count, 2, "a static property")
        XCTAssertEqual(changes("var isEmpty").count, 2, "a getter's one expression")
        XCTAssertEqual(changes("subscript"), ["< → !=", "index < count → false"], "a subscript")
        XCTAssertEqual(changes("let isGlobal").count, 2, "a global")
        XCTAssertEqual(changes("let isLoaded"), ["< → !=", "try load(items.count) < 3 → false"], "a try alone")
        XCTAssertEqual(
            changes("let both"),
            ["> → !=", "load(1) <= 1 → true", "<= → =="],
            "a try over more than the comparison: no constant for the comparison it's written in front of"
        )
        XCTAssertEqual(changes("let isFetched").count, 2, "an await")
        XCTAssertEqual(changes("let paired"), ["== → !="], "a sequence the standard table can't fold")
        XCTAssertEqual(changes("let label").count, 2, "a ternary's condition")
        XCTAssertEqual(changes("let large"), ["> → !="], "a closure's only $0")
        XCTAssertEqual(changes("let sorted"), ["> → !=", "a > b → false"], "a closure that names its parameters")
        XCTAssertEqual(changes("while index").count, 2, "a while condition")
        XCTAssertEqual(changes("while steps <= 2"), ["<= → =="], "a while condition, without `true`")
        XCTAssertEqual(changes("while steps != 5"), ["steps != 5 → false"], "a repeat-while condition, without `true`")
        XCTAssertEqual(changes("guard items").count, 2, "a guard condition")
        XCTAssertEqual(changes("if items.count"), ["< → !=", "items.count + 1 < 10 → false"], "inside more")
        XCTAssertEqual(changes("expect(items.count) == 2"), ["== → !="], "a statement")
        XCTAssertEqual(changes("expect(items.count) < 3"), ["< → !="], "a statement")
        XCTAssertEqual(changes("return(value").count, 2, "a value touching return")

        try assertComparisonsRun(compiled)
    }

    /// Runs the comparisons program with no mutant, then with the swap, each constant and a statement switched on.
    private func assertComparisonsRun(_ compiled: Compiled) throws {
        let first = "false false false true true\n== true\n< true\ntrue true true true many 1 [2, 1] 3\n"
        XCTAssertEqual(try run(compiled.program).output, first + "false true true false\n", "no mutant named")
        // The swap and each constant are switched on by themselves: `ordered` and `same` give each value.
        for (line, after, output) in [
            ("return(value", "!=", "true true true false\n"),
            ("return(value", "false", "false false true false\n"),
            ("func same", "true", "false true true true\n"),
            ("func same", "false", "false true false false\n"),
        ] {
            let mutant = try XCTUnwrap(
                compiled.mutants(in: "Comparisons.swift", onTheLineHolding: line)
                    .first { $0.mutationOperatorId == .ror && $0.snapshot.after == after }
            )
            XCTAssertEqual(try run(compiled.program, switchingOn: mutant.id).output, first + output, "\(line) \(after)")
        }
        let statement = try XCTUnwrap(
            compiled.mutants(in: "Comparisons.swift", onTheLineHolding: "expect(items.count) == 2")
                .first { $0.mutationOperatorId == .ror }
        )
        XCTAssertEqual(
            try run(compiled.program, switchingOn: statement.id).output,
            "false false false true true\n!= false\n< true\ntrue true true true many 1 [2, 1] 3\n"
                + "false true true false\n"
        )
    }

    private static let comparisonsCode = """
    struct Expectation {
        let value: Int
        static func == (lhs: Expectation, rhs: Int) { print("==", lhs.value == rhs) }
        static func != (lhs: Expectation, rhs: Int) { print("!=", lhs.value != rhs) }
        static func < (lhs: Expectation, rhs: Int) { print("<", lhs.value < rhs) }
        static func <= (lhs: Expectation, rhs: Int) { print("<=", lhs.value <= rhs) }
    }

    func expect(_ value: Int) -> Expectation { Expectation(value: value) }

    precedencegroup PairingPrecedence { higherThan: ComparisonPrecedence }
    infix operator <~>: PairingPrecedence
    func <~> (lhs: Int, rhs: Int) -> Int { lhs * 10 + rhs }

    struct Limits {
        var count: Int
        var isFull = CommandLine.arguments.count >= 5
        static let isDebug = CommandLine.arguments.count == 3
        var isEmpty: Bool { count == 0 }
        subscript(index: Int) -> Bool { index < count }
    }

    let isGlobal = CommandLine.arguments.count != 100

    func load(_ count: Int) throws -> Int { count }

    func fetch(_ count: Int) async -> Int { count }

    func check(_ items: [Int]) async throws -> String {
        let isLoaded = try load(items.count) < 3
        let both = try load(items.count) > 0 && load(1) <= 1
        let isFetched = await fetch(items.count) == 2
        let paired = 1 <~> 2 == 12
        let label = items.count == 1 ? "one" : "many"
        let large = items.filter { $0 > 1 }.count
        let sorted = items.sorted { a, b in a > b }
        var index = 0
        while index < 3 {
            index += 1
        }
        var steps = 0
        while steps <= 2 {
            steps += 1
        }
        repeat {
            steps += 1
        } while steps != 5
        guard items.count >= 0 else { return "none" }
        if items.count + 1 < 10 && !items.isEmpty {
            expect(items.count) == 2
            expect(items.count) < 3
        }
        return "\\(isLoaded) \\(both) \\(isFetched) \\(paired) \\(label) \\(large) \\(sorted) \\(index)" // why
    }

    func ordered(_ value: Int) -> Bool {
        return(value > 1)
    }

    func same(_ value: Int) -> Bool { value == 2 }
    """
}
