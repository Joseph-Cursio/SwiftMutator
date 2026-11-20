@testable import muterCore
import XCTest

/// ReplaceNilCoalescing's shapes, compiled with the real compiler as `GeneratedCodeShapesTests` compiles the others'.
extension GeneratedCodeShapesTests {
    /// Each place a `??` is replaced: a chain, a term inside a comparison, one under a `try` whose fallback throws, an
    /// annotated binding of a literal read as a Double, a default argument, a stored property, a `static`, a global,
    /// a closure, a string interpolation and an `await` around a call. All of them must compile together, each in a
    /// branch of its own, and a chain's two links are switched on by themselves. An unannotated binding of a literal
    /// gets no mutant, as `let z = 0` would be an Int whatever `d` held.
    func test_theGeneratedCodeBuildsForCoalescings() throws {
        leftOutOperators = MutationOperatorList.allOperators.filter { $0 != .replaceNilCoalescing }
        let code = Self.coalescingsCode
        let main = driver("""
        let box = Box()
        print(chain(nil, 2), chain(1, 2), chain(nil, nil))
        print(compare(3), try loaded(1), try loaded(3), scaled(2), counted(nil), defaulted() as Any)
        print(mapped([1, nil]), await waited(7), await waited(1), Box.shared, box.stored, box.describe(nil),
              globalCount)
        """)
        let compiled = try compileMutated(["Coalescings.swift": code], plain: ["main.swift": main])

        let replaced = { (text: String) -> Int in
            compiled.mutants(in: "Coalescings.swift", onTheLineHolding: text)
                .filter { $0.mutationOperatorId == .replaceNilCoalescing }.count
        }
        XCTAssertEqual(replaced("return a"), 1, "a chain's outer link")
        XCTAssertEqual(replaced("?? b ?? -1"), 1, "a chain's inner link, placed on its own line")
        XCTAssertEqual(replaced("x ?? 0 + 1"), 1, "a term inside a comparison")
        XCTAssertEqual(replaced("try cached"), 1, "a try over a fallback that throws")
        XCTAssertEqual(replaced("let y: Double"), 1, "an annotated binding of a literal")
        XCTAssertEqual(replaced("let z ="), 0, "an unannotated binding of a literal")
        XCTAssertEqual(replaced("func defaulted"), 1, "a default argument")
        XCTAssertEqual(replaced("var stored"), 1, "a stored property")
        XCTAssertEqual(replaced("static let shared"), 1, "a static")
        XCTAssertEqual(replaced("let globalCount"), 1, "a global")
        XCTAssertEqual(replaced("item in"), 1, "a closure")
        XCTAssertEqual(replaced("box \\("), 1, "a string interpolation")
        XCTAssertEqual(replaced("await total"), 1, "an await around a call")

        let first = "2 1 -1\n"
        let rest = "true 30 3 5.0 1 Optional(8)\n[1, 9] 107 101 3 4 box none 5\n"
        XCTAssertEqual(try run(compiled.program).output, first + rest, "no mutant named")
        // The outer link always takes `b ?? -1`, and the inner one `a ?? -1`.
        for (before, output) in [("a ?? b ?? -1", "2 2 -1\n"), ("b ?? -1", "-1 1 -1\n")] {
            let id = try compiled.identifier(in: "Coalescings.swift") {
                $0.mutationOperatorId == .replaceNilCoalescing && $0.snapshot.before == before
            }
            XCTAssertEqual(try run(compiled.program, switchingOn: id).output, output + rest, before)
        }
    }

    private static let coalescingsCode = #"""
    func cached(_ n: Int) throws -> Int? { n > 2 ? n : nil }
    func load(_ n: Int) throws -> Int { n * 30 }
    func peek(_ n: Int) async -> Int? { n > 5 ? n : nil }
    func total(of n: Int) async -> Int { n + 100 }

    struct Box {
        static let seed = 4
        static let shared: Int = Int("x") ?? 3
        var stored = Int("y") ?? Box.seed
        func describe(_ name: String?) -> String { "box \(name ?? "none")" }
    }

    let globalCount = Int("z") ?? Box.seed + 1

    func chain(_ a: Int?, _ b: Int?) -> Int {
        return a
            ?? b ?? -1
    }

    func compare(_ x: Int?) -> Bool {
        x ?? 0 + 1 < 5
    }

    func loaded(_ n: Int) throws -> Int {
        try cached(n) ?? load(n)
    }

    func scaled(_ d: Double?) -> Double {
        let y: Double = d ?? 0
        return y * 2.5
    }

    func counted(_ d: Int?) -> Int {
        let z = d ?? 0
        return z + 1
    }

    func defaulted(_ value: Int? = Int("q") ?? 8) -> Int? { value }

    func mapped(_ items: [Int?]) -> [Int] {
        items.map { item in item ?? 9 }
    }

    func waited(_ n: Int) async -> Int {
        await total(of: peek(n) ?? n)
    }
    """#
}
