@testable import muterCore
import XCTest

extension GeneratedCodeShapesTests {
    /// Each link of a chain gets a swap of its own, in whatever a link can hold: an assignment or a closure that can't
    /// end the list without parentheses, a comment between links, `try` before the chain, an interpolation, a value
    /// outside a function.
    func test_theGeneratedCodeBuildsForEveryLinkOfATernaryChain() throws {
        let chains = """
        nonisolated(unsafe) var total = 0
        func work() {}
        func load(_ value: Int) throws -> Int { value }

        let label = total > 1 ? "many" : total > 0 ? "one" : "none"

        func assign(_ a: Bool, _ b: Bool) {
            a ? total = 1 : b ? total += 1 : work()
            b ? work() : a ? total = 2 : (total = 3)
        }

        func close(_ a: Bool, _ b: Bool) -> Int {
            guard a ? true : b ? { false }() : a else { return 0 }
            return 1
        }

        func commented(_ a: Bool, _ b: Bool) -> Int {
            return a ? 1 // first
                // second
                : b ? 2 /* third */
                : 3 // fourth
        }

        func attempt(_ a: Bool, _ b: Bool) throws -> Int {
            return try a ? load(1) : b ? load(2) : load(3) + 1
        }

        func interpolate(_ a: Bool, _ b: Bool) -> String {
            return "\\(a ? 1 : b ? 2 : 3)"
        }
        """
        let main = driver("""
        assign(true, false)
        print(close(true, false), commented(true, false), interpolate(true, false), label)
        print(try attempt(true, false))
        """)
        let compiled = try compileMutated(["Chains.swift": chains], plain: ["main.swift": main])

        let swaps = compiled.mutants(in: "Chains.swift").filter { $0.mutationOperatorId == .swapTernary }
        XCTAssertEqual(swaps.count, 14, "\(swaps.map(\.snapshot.before))")
    }

    /// A ternary's swap moves its whole else branch, however long: a chain, a nested ternary, a call with a closure,
    /// optional chaining, an interpolation, an operator, a branch over several lines with a comment, a postfix `#if`
    /// ending either branch, in a statement or a call, a comment between the condition and the `?`, a `try await`
    /// over it. A then branch that ends in a closure's brace is put in parentheses, which only a `guard` condition
    /// needs, so the rewritten text is checked for it. A body opened on its brace's line that ends in a comment
    /// keeps the brace that closes its switch off the comment's line.
    func test_theGeneratedCodeBuildsInTernariesThatHoldLongerExpressions() throws {
        leftOutOperators = [.replaceReturnValue]
        let ternaries = Self.longerTernariesCode
        let main = driver("""
        print(describe([Item(name: "a", tags: [])], limit: 1))
        print(try await fetched(true))
        """)
        let compiled = try compileMutated(["Ternaries.swift": ternaries], plain: ["main.swift": main])

        let swaps = compiled.mutants(in: "Ternaries.swift").filter { $0.mutationOperatorId == .swapTernary }
        let swapped = { text in swaps.filter { $0.snapshot.before.hasPrefix(text) }.count }
        XCTAssertEqual(swapped("items.first?.name?.isEmpty"), 1, "optional chaining: \(swaps)")
        XCTAssertEqual(swapped("items.count > limit"), 1, "a chain's first link: \(swaps)")
        XCTAssertEqual(swapped("items.count > 1"), 1, "a ternary holding a nested one: \(swaps)")
        XCTAssertEqual(swapped("limit > 2"), 1, "the nested ternary: \(swaps)")
        XCTAssertEqual(swapped("items.isEmpty ? \"none\""), 1, "a chain's later link: \(swaps)")
        XCTAssertEqual(swapped("items.isEmpty ? [] : items.map"), 1, "a closure in the else branch: \(swaps)")
        XCTAssertEqual(swapped("items.isEmpty ? items.map"), 1, "a closure in the then branch: \(swaps)")
        XCTAssertEqual(swapped("limit > 0 ? {"), 1, "closures: \(swaps)")
        XCTAssertEqual(swapped("limit > 0 ? items.compactMap"), 1, "an operator in the else branch: \(swaps)")
        XCTAssertEqual(swapped("items.count == 1"), 1, "in an interpolation: \(swaps)")
        XCTAssertEqual(swapped("counted.reduce(0, +) > 0"), 1, "in an interpolation: \(swaps)")
        XCTAssertEqual(swapped("limit > 3"), 1, "over several lines: \(swaps)")
        XCTAssertEqual(swapped("limit > 0 ? items #if"), 1, "a then branch ending in #endif: \(swaps)")
        XCTAssertEqual(swapped("limit > 0 ? [] : counted #if"), 1, "an else branch ending in #endif: \(swaps)")
        XCTAssertEqual(swapped("limit > 1 ? counted #if"), 1, "a then branch ending in #endif in a call: \(swaps)")
        XCTAssertEqual(swapped("limit > 0 // positive"), 1, "a comment after the condition: \(swaps)")
        XCTAssertEqual(swapped("try await flag ?"), 1, "under try await: \(swaps)")
        let positive = compiled.mutants(in: "Ternaries.swift", onTheLineHolding: "func isPositive")
        XCTAssertEqual(
            positive.map(\.mutationOperatorId),
            [.replaceBooleanValue, .relationalBoundary, .ror, .ror, .replaceBooleanValue],
            "a body ending in a comment on its brace's line"
        )
        let rewritten = compiled.rewritten["Ternaries.swift"] ?? ""
        XCTAssertTrue(
            rewritten.contains("(items.map { $0.tags.count })"),
            "a then branch ending in a closure's brace, not in parentheses:\n\(rewritten)"
        )

        try assertLongerTernariesRun(compiled)
    }

    /// Runs the ternaries program with no mutant, then with two of its swaps switched on.
    private func assertLongerTernariesRun(_ compiled: Compiled) throws {
        let original = "a|some|c|a|item: plain|1|1|2|0|0|yes|true\n1\n"
        XCTAssertEqual(try run(compiled.program).output, original, "no mutant named")
        let joined = try compiled.identifier(in: "Ternaries.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("limit > 0 ? items.compactMap")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: joined).output,
            "a|some|c|-1|item: plain|1|1|2|0|0|yes|true\n1\n",
            "the whole else branch swapped in"
        )
        let awaited = try compiled.identifier(in: "Ternaries.swift") { $0.snapshot.before.hasPrefix("try await") }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: awaited).output,
            "a|some|c|a|item: plain|1|1|2|0|0|yes|true\n3\n",
            "the ternary under try await swapped"
        )
    }

    private static let longerTernariesCode = """
    struct Item {
        var name: String?
        var tags: [String]
    }

    func describe(_ items: [Item], limit: Int) -> String {
        let first = items.first?.name?.isEmpty == false ? items.first?.name ?? "" : "unnamed"
        let size = items.count > limit ? "many" : items.isEmpty ? "none" : "some"
        let nested = items.count > 1 ? (limit > 2 ? "a" : "b") : "c"
        let counted = items.isEmpty ? [] : items.map { $0.tags.count }
        let mapped = items.isEmpty ? items.map { $0.tags.count } : []
        let next = limit > 0 ? { (value: Int) in value + 1 } : { (value: Int) in value - 1 }
        let joined = limit > 0 ? items.compactMap(\\.name).joined(separator: ", ") : "-" + "\\(limit)"
        let text = "\\(items.count == 1 ? "item" : "items"): \\(counted.reduce(0, +) > 0 ? "tagged" : "plain")"
        let spread = limit > 3
            ? counted.reduce(0, +) * 2 // doubled
            : counted.count + mapped.count
        let shown = limit > 0
            ? items
            #if !SWIFTMUTATOR_NEVER_DEFINED
                .filter { $0.name != nil }
            #endif
            : []
        let kept = limit > 0 ? []
            : counted
            #if !SWIFTMUTATOR_NEVER_DEFINED
                .filter { $0 > 1 }
            #endif
        let keptCount = Array(limit > 1 ? counted
            #if !SWIFTMUTATOR_NEVER_DEFINED
                .filter { $0 >= 0 }
            #endif
            : []).count
        let counts = "\\(spread)|\\(shown.count)|\\(next(1))|\\(kept.count)|\\(keptCount)"
        return [first, size, nested, joined, text, counts, sign(of: limit), "\\(isPositive(limit))"]
            .joined(separator: "|")
    }

    func sign(of limit: Int) -> String {
        return limit > 0 // positive
            ? "yes" : "no"
    }

    func isPositive(_ limit: Int) -> Bool { limit > 0 // positive
    }

    func load(_ value: Int) async throws -> Int { value }

    func fetched(_ flag: Bool) async throws -> Int { try await flag ? load(1) : load(2) + 1 }
    """
}
