@testable import muterCore
import XCTest

extension GeneratedCodeShapesTests {
    /// A single-expression body of a computed property or function whose type is `some …`, and isn't a result
    /// builder, is switched as an `if` expression, whose branches must share one type; a body of several statements
    /// as an `if` statement with a `return` in each branch. The mutants nested in such a body are dropped, whether
    /// the body is a property's, a function's or an explicit getter's: a nested switch in a builder closure there
    /// would change the type of one branch only.
    func test_theGeneratedCodeBuildsInAnOpaqueBodyThatIsNotAResultBuilder() throws {
        let opaque = Self.opaqueBodiesCode
        let main = driver("""
        let choice = Choice(count: 2)
        print(Counter(count: 2).label, choice.chosen, choice.picked(2), choice.gotten)
        """)
        let compiled = try compileMutated(["Opaque.swift": opaque], plain: ["main.swift": main])

        let mutants = { compiled.operators(in: "Opaque.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("var label"), [.ror, .relationalBoundary, .swapTernary], "a property's single expression"
        )
        // A `some` type written isn't `Bool`, so ReplaceBooleanValue leaves these alone.
        XCTAssertEqual(
            mutants("var isBusy"), [.ror, .relationalBoundary, .logicalOperator], "a property's single condition"
        )
        XCTAssertEqual(mutants("get { count != 1 }"), [.ror], "a getter's single expression")
        XCTAssertEqual(
            mutants("var sizes"), [.ror, .relationalBoundary], "a closure in a body with no mutant of its own"
        )
        XCTAssertEqual(mutants("func shape"), [.ror, .swapTernary], "a function's single expression")
        XCTAssertEqual(
            mutants("return product"), [.ror, .relationalBoundary, .swapTernary], "a body of several statements"
        )
        let chosen = compiled.mutants(in: "Opaque.swift", onTheLineHolding: "var chosen")
        XCTAssertEqual(
            chosen.map(\.snapshot.before), [">", ">", "count > 5"], "only the property's own mutants, not the closure's"
        )
        let picked = compiled.mutants(in: "Opaque.swift", onTheLineHolding: "func picked")
        XCTAssertEqual(
            picked.map(\.snapshot.before), [">", ">", "limit > 5"], "only the function's own mutants, not the closure's"
        )
        let gotten = compiled.mutants(in: "Opaque.swift", onTheLineHolding: "get { tagged")
        XCTAssertEqual(
            gotten.map(\.snapshot.before),
            ["count >= 5", ">=", ">="],
            "only the getter's own mutants, not the closure's"
        )

        let tagged = #"("big", false)"#
        let original = "many \(tagged) \(tagged) \(tagged)\n"
        XCTAssertEqual(try run(compiled.program).output, original, "no mutant named")
        let inTheLabel = try compiled.identifier(in: "Opaque.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("count > 1 ? \"many\"")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheLabel).output,
            "one \(tagged) \(tagged) \(tagged)\n",
            "the label's ternary swapped"
        )
    }

    private static let opaqueBodiesCode = """
    protocol Shape {
        var sides: Int { get }
    }

    struct Polygon: Shape {
        let sides: Int
    }

    struct Counter {
        var count: Int

        var label: some StringProtocol { count > 1 ? "many" : "one" }

        var isBusy: some Equatable { count >= 3 && count < 10 }

        var explicit: some Equatable {
            get { count != 1 }
        }

        var sizes: some Collection<Int> { [count, 2].filter { $0 > 1 } }

        func shape() -> some Shape { Polygon(sides: count == 0 ? 3 : count) }

        func scaled(by factor: Int) -> some Equatable {
            let product = count * factor
            return product > 10 ? product : -product
        }
    }

    enum Either<First, Second> {
        case first(First)
        case second(Second)
    }

    @resultBuilder enum Pick {
        static func buildBlock<Component>(_ component: Component) -> Component { component }
        static func buildEither<First, Second>(first: First) -> Either<First, Second> { .first(first) }
        static func buildEither<First, Second>(second: Second) -> Either<First, Second> { .second(second) }
    }

    func pick<Component>(@Pick _ make: () -> Component) -> Component { make() }

    func tagged<Value>(_ value: Value, _ isMarked: Bool) -> (Value, Bool) { (value, isMarked) }

    struct Choice {
        var count: Int

        var chosen: some Any { tagged(pick { count > 1 ? "big" : "small" }, count > 5) }

        func picked(_ limit: Int) -> some Any { tagged(pick { limit > 1 ? "big" : "small" }, limit > 5) }

        var gotten: some Any {
            get { tagged(pick { count >= 1 ? "big" : "small" }, count >= 5) }
        }
    }
    """
}
