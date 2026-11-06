@testable import muterCore
import XCTest

/// Compiles the generated code of shapes of Swift whose switches are easy to get wrong, with the real compiler, and
/// runs it where that's cheap. Each test is named for its shape, so a failure names the shape that broke, and each
/// checks that the rewrite found mutants of that shape, so a fixture can't pass by holding none.
final class GeneratedCodeShapesTests: GeneratedCodeTestCase {
    /// A result builder takes a switch as an `if` with an `else`, so it needs `buildEither`. A mutant in a builder
    /// closure's statement or `if` condition is switched in the closure's statements, and one in an `if` or `for`
    /// body in that body's, each of which is a component the builder combines. A builder property's or function's
    /// own statements are switched as well.
    func test_theGeneratedCodeBuildsInAResultBuilder() throws {
        let lines = """
        @resultBuilder enum Lines {
            static func buildExpression(_ line: String) -> [String] { [line] }
            static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }
            static func buildOptional(_ part: [String]?) -> [String] { part ?? [] }
            static func buildEither(first part: [String]) -> [String] { part }
            static func buildEither(second part: [String]) -> [String] { part }
            static func buildArray(_ parts: [[String]]) -> [String] { parts.flatMap { $0 } }
        }

        func lines(@Lines _ make: () -> [String]) -> [String] { make() }

        func report(_ values: [Int]) -> [String] {
            lines {
                "start"
                if values.count > 1 {
                    "many"
                } else if values.isEmpty || values.count == 1 {
                    "few"
                }
                for value in values {
                    value > 1 ? "big" : "small"
                }
                values.count >= 3 && values.first != nil ? "long" : "short"
            }
        }

        @Lines var banner: [String] {
            "banner"
            if CommandLine.arguments.count > 0 { "with arguments" }
        }

        @Lines func footer(_ count: Int) -> [String] {
            count != 1 ? "items" : "item"
        }
        """
        let compiled = try compileMutated(
            ["Lines.swift": lines],
            plain: ["main.swift": driver(#"print((report([5, 0]) + banner + footer(2)).joined(separator: ","))"#)]
        )

        let mutants = { compiled.operators(in: "Lines.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("if values.count > 1"), [.ror, .relationalBoundary, .negateConditional], "an if's condition"
        )
        XCTAssertEqual(
            mutants("values.isEmpty || values"), [.ror, .logicalOperator, .negateConditional], "an else if's condition"
        )
        XCTAssertEqual(mutants("value > 1 ?"), [.ror, .relationalBoundary, .swapTernary], "a component in a for body")
        XCTAssertEqual(
            mutants("values.count >= 3"), [.ror, .relationalBoundary, .logicalOperator, .swapTernary], "a component"
        )
        XCTAssertEqual(
            mutants("CommandLine.arguments"),
            [.ror, .relationalBoundary, .negateConditional],
            "a builder property's if condition"
        )
        XCTAssertEqual(mutants("count != 1"), [.ror, .swapTernary], "a builder function's component")

        let original = "start,many,big,small,short,banner,with arguments,items"
        XCTAssertEqual(try run(compiled.program).output, original + "\n", "no mutant named")
        let inTheForBody = try compiled.identifier(in: "Lines.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("value > 1")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheForBody).output,
            "start,many,small,big,short,banner,with arguments,items\n",
            "the for body's ternary swapped"
        )
    }

    /// SwiftUI's `ViewBuilder`: a view's `body` is a builder, so the mutants nested in it are kept, and a modifier's
    /// argument there switches the whole body. A view property that isn't `body` is an opaque body that isn't a
    /// builder: a switch there is an `if` expression.
    func test_theGeneratedCodeBuildsInASwiftUIViewBuilder() throws {
        #if canImport(SwiftUI)
        let row = """
        import SwiftUI

        struct Row: View {
            var count: Int

            var body: some View {
                VStack {
                    Text(count > 1 ? "many" : "one")
                    if count >= 3 && count < 10 {
                        Text("several")
                    } else {
                        EmptyView()
                    }
                    badge
                }
                .opacity(count > 0 ? 1 : 0.5)
            }

            private var badge: some View {
                Text(count != 1 ? "items" : "item").bold()
            }
        }
        """
        let compiled = try compileMutated(["Row.swift": row])

        let mutants = { compiled.operators(in: "Row.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("Text(count > 1"), [.ror, .relationalBoundary, .swapTernary], "a component in the body's VStack"
        )
        XCTAssertEqual(
            mutants("if count >= 3"),
            [.ror, .relationalBoundary, .logicalOperator, .negateConditional],
            "an if's condition in the VStack"
        )
        XCTAssertEqual(mutants(".opacity"), [.ror, .relationalBoundary, .swapTernary], "a modifier's argument")
        XCTAssertEqual(mutants("count != 1"), [.ror, .swapTernary], "a view property that isn't body")
        #else
        throw XCTSkip("SwiftUI is only on Apple's platforms")
        #endif
    }

    /// A single-expression body of a computed property or function whose type is `some …`, and isn't a result
    /// builder, is switched as an `if` expression, whose branches must share one type; a body of several statements
    /// as an `if` statement with a `return` in each branch. The mutants nested in such a body are dropped, whether
    /// the body is a property's, a function's or an explicit getter's: a nested switch in a builder closure there
    /// would change the type of one branch only.
    func test_theGeneratedCodeBuildsInAnOpaqueBodyThatIsNotAResultBuilder() throws {
        let opaque = """
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
        let main = driver("""
        let choice = Choice(count: 2)
        print(Counter(count: 2).label, choice.chosen, choice.picked(2), choice.gotten)
        """)
        let compiled = try compileMutated(["Opaque.swift": opaque], plain: ["main.swift": main])

        let mutants = { compiled.operators(in: "Opaque.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("var label"), [.ror, .relationalBoundary, .swapTernary], "a property's single expression"
        )
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
        XCTAssertEqual(chosen.map(\.snapshot.before), [">", ">"], "only the property's own mutants, not the closure's")
        let picked = compiled.mutants(in: "Opaque.swift", onTheLineHolding: "func picked")
        XCTAssertEqual(picked.map(\.snapshot.before), [">", ">"], "only the function's own mutants, not the closure's")
        let gotten = compiled.mutants(in: "Opaque.swift", onTheLineHolding: "get { tagged")
        XCTAssertEqual(gotten.map(\.snapshot.before), [">=", ">="], "only the getter's own mutants, not the closure's")

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

    /// A `#if` at file scope, around declarations, with mutants in the active clause and in the inactive ones:
    /// discovery visits every clause, and an inactive clause's switches need only parse. A mutant whose nearest
    /// statements are the file's, or those of a clause that declares something, is refused, since a switch can't go
    /// there; that refusal alone keeps out the mutants of a file-scope `#if` condition. A `#if` in a function's
    /// statements, where a switch can go, shows that its condition is never mutated: a switch there would split the
    /// directive. The flag is one nobody defines, so the same clause is active on every machine.
    func test_theGeneratedCodeBuildsAroundAFileScopeIf() throws {
        let modes = """
        #if SWIFTMUTATOR_NEVER_DEFINED
        func mode(_ value: Int) -> String { value > 1 ? "inactive big" : "inactive small" }
        #elseif !SWIFTMUTATOR_NEVER_DEFINED && (os(macOS) || os(Linux))
        func mode(_ value: Int) -> String { value >= 1 && value < 100 ? "big" : "small" }
        #else
        func mode(_ value: Int) -> String { value != 0 ? "other big" : "other small" }
        #endif

        #if (SWIFTMUTATOR_NEVER_DEFINED || os(Windows))
        enum Limits { static let isLarge = Int.max > 2 }
        #else
        enum Limits { static let isLarge = Int.max > 1 }
        #endif

        struct Settings {
            var count = 1
            #if !SWIFTMUTATOR_NEVER_DEFINED
            var level: Int { count > 0 ? 2 : 3 }
            #endif
        }

        func size(of value: Int) -> Int {
            #if os(Windows) || !SWIFTMUTATOR_NEVER_DEFINED
            return value > 1 ? 2 : 3
            #else
            return 0
            #endif
        }
        """
        let compiled = try compileMutated(
            ["Modes.swift": modes],
            plain: ["main.swift": driver("print(mode(5), Settings().level, Limits.isLarge, size(of: 5))")]
        )

        let mutants = { compiled.operators(in: "Modes.swift", onTheLineHolding: $0) }
        XCTAssertEqual(mutants("inactive big"), [.ror, .relationalBoundary, .swapTernary], "the inactive #if clause")
        XCTAssertEqual(
            mutants("? \"big\""),
            [.ror, .relationalBoundary, .logicalOperator, .swapTernary],
            "the active #elseif clause"
        )
        XCTAssertEqual(mutants("other big"), [.ror, .swapTernary], "the inactive #else clause")
        XCTAssertEqual(
            mutants("var level"),
            [.ror, .relationalBoundary, .swapTernary],
            "a getter in a #if clause of a type's members"
        )
        XCTAssertEqual(mutants("#elseif"), [], "a #if condition, in the file's statements")
        XCTAssertEqual(mutants("#if (SWIFTMUTATOR"), [], "a #if condition in parentheses, in the file's statements")
        XCTAssertEqual(mutants("#if os(Windows)"), [], "a #if condition in a function's statements")
        XCTAssertEqual(
            mutants("return value > 1"),
            [.ror, .relationalBoundary, .swapTernary],
            "a #if clause of a function's statements"
        )
        XCTAssertEqual(mutants("Int.max > 2"), [.ror, .relationalBoundary], "a stored property, switched in its value")
        XCTAssertEqual(mutants("Int.max > 1"), [.ror, .relationalBoundary], "a stored property, switched in its value")
        let rewritten = compiled.rewritten["Modes.swift"] ?? ""
        XCTAssertFalse(
            rewritten.contains("\nif __SwiftMutator_"),
            "a switch in the file's own statements:\n\(rewritten)"
        )

        XCTAssertEqual(try run(compiled.program).output, "big 2 true 2\n", "no mutant named")
        let inTheActiveClause = try compiled.identifier(in: "Modes.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("value >= 1")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheActiveClause).output,
            "small 2 true 2\n",
            "the active clause's ternary swapped"
        )
    }

    /// The arithmetic and literal mutants that have nowhere but a value to go, as well as those in statements, and a
    /// `+` beside what shows it holds numbers. All of them must compile together, each in a branch of its own.
    func test_theGeneratedCodeBuildsForArithmeticAndLiterals() throws {
        let code = """
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
        XCTAssertEqual(mutants("return total +"), [.arithmeticOperator], "a count")
        XCTAssertEqual(
            mutants("case true:"),
            [.ror, .flipBooleanLiteral],
            "what a case runs, but not its pattern"
        )
        XCTAssertEqual(mutants("while true"), [], "a whole condition")
        XCTAssertEqual(mutants("if true { return 1 }"), [], "a whole condition")
        XCTAssertEqual(mutants("#if true"), [], "a directive's condition")
        XCTAssertEqual(mutants("var result"), [], "a + of strings")
        XCTAssertEqual(mutants("result += name"), [], "a += of strings")
        XCTAssertEqual(mutants("let compiled"), [.flipBooleanLiteral], "a directive's code")
    }

    /// A `main.swift` of top-level code. Its own statements hold a declaration, the `ProcessInfo` import added in
    /// front if nothing else, so a mutant there is switched in its statement or a global's value alone; one in a `for`
    /// or `if` body, a closure, a function, or a `#if` clause of statements only is switched there. The switches read
    /// the cache declared after them, at the file's end.
    func test_theGeneratedCodeBuildsInTopLevelCode() throws {
        let main = driver("""
        func doubled(_ value: Int) -> Int { value > 0 ? value * 2 : 0 }

        let values = CommandLine.arguments.count > 5 ? [9] : [1, 5]
        var total = 0
        for value in values {
            total += value > 1 ? value : 0
        }
        let isLarge = { (value: Int) -> Bool in value > 1 }
        #if !SWIFTMUTATOR_NEVER_DEFINED
        print(total >= 5 && values.count != 0 ? "large" : "small")
        #endif
        if total < 100 {
            print(isLarge(total) ? "original" : "mutant", doubled(total))
        }
        """)
        let compiled = try compileMutated(["main.swift": main])

        let mutants = { compiled.operators(in: "main.swift", onTheLineHolding: $0) }
        XCTAssertEqual(
            mutants("func doubled"),
            [.ror, .relationalBoundary, .swapTernary, .arithmeticOperator],
            "a function"
        )
        XCTAssertEqual(mutants("let values"), [.ror, .relationalBoundary, .swapTernary], "a global's value")
        XCTAssertEqual(mutants("total += value"), [.ror, .relationalBoundary, .swapTernary], "a for body")
        XCTAssertEqual(mutants("let isLarge"), [.ror, .relationalBoundary], "a closure")
        XCTAssertEqual(
            mutants("total >= 5"),
            [.ror, .relationalBoundary, .logicalOperator, .swapTernary],
            "a #if clause of statements"
        )
        XCTAssertEqual(mutants("if total < 100"), [.negateConditional, .ror, .relationalBoundary], "an if's condition")
        XCTAssertEqual(mutants("print(isLarge"), [.swapTernary], "an if body")

        XCTAssertEqual(try run(compiled.program).output, "large\noriginal 10\n", "no mutant named")
        let inTheClosure = try XCTUnwrap(
            compiled.mutants(in: "main.swift", onTheLineHolding: "let isLarge").first { $0.mutationOperatorId == .ror }
        ).id
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheClosure).output,
            "large\nmutant 10\n",
            "the closure's comparison changed"
        )
        let inTheIf = try compiled.identifier(in: "main.swift") {
            $0.mutationOperatorId == .swapTernary && $0.snapshot.before.hasPrefix("total >= 5")
        }
        XCTAssertEqual(
            try run(compiled.program, switchingOn: inTheIf).output,
            "small\noriginal 10\n",
            "the #if clause's ternary swapped"
        )
    }

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
        let ternaries = """
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
            [.relationalBoundary, .ror],
            "a body ending in a comment on its brace's line"
        )
        let rewritten = compiled.rewritten["Ternaries.swift"] ?? ""
        XCTAssertTrue(
            rewritten.contains("(items.map { $0.tags.count })"),
            "a then branch ending in a closure's brace, not in parentheses:\n\(rewritten)"
        )

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

    // MARK: - Known bugs

    // Each of these is a shape whose generated code doesn't compile, so the shared build of every mutant fails. Each is
    // skipped until the rewriter, or the operator that makes the mutant, is fixed; take its skip out then.

    /// A result builder with no `buildEither` can't take an `if` with an `else`, so a switch in its closure doesn't
    /// compile: "closure containing control flow statement cannot be used with result builder 'Sum'" (#206).
    func test_theGeneratedCodeBuildsInAResultBuilderWithoutBuildEither() throws {
        try XCTSkipIf(true, "a switch in a builder without buildEither doesn't compile; see #206")
        let sum = """
        @resultBuilder enum Sum {
            static func buildBlock(_ parts: Int...) -> Int { parts.reduce(0, +) }
        }

        func sum(@Sum _ make: () -> Int) -> Int { make() }

        func total(_ value: Int) -> Int { sum { value > 1 ? 10 : 20 } }
        """
        _ = try compileMutated(["Sum.swift": sum])
    }

    /// RemoveSideEffects removing the call to a function that never returns, the last statement of a `guard` body or
    /// of a function that returns a value, leaves code that falls through: "'guard' body must not fall through" and
    /// "missing return in global function expected to return 'Int'". Only a full build finds the first; a type check
    /// doesn't. #112 tracks the `guard` body; the function that returns a value is the same bug in another place.
    func test_theGeneratedCodeBuildsWithoutACallThatNeverReturns() throws {
        try XCTSkipIf(true, "RemoveSideEffects removing a call that never returns doesn't compile; see #112")
        let usage = """
        func usage() -> Never {
            while true {}
        }

        func check(_ arguments: [String]) -> Int {
            guard arguments.count > 1 else {
                usage()
            }
            return arguments.count
        }

        func value(_ arguments: [String]) -> Int {
            print(arguments)
            usage()
        }
        """
        _ = try compileMutated(["Usage.swift": usage])
    }
}
