@testable import muterCore
import XCTest

extension ReplaceBooleanValueOperatorTests {
    // The syntax tree has no types, and these hold no sign of a Bool.
    func test_aValueOfNoWrittenBoolAndNoOperator_doesntCount() throws {
        for code in [
            "func f() { let x = items.isEmpty }",
            "func f() { let x: Bool? = flag }",
            "func f() { let x: Bool! = flag }",
            "func f() -> Bool? { flag }",
            "func f() -> Optional<Bool> { flag }",
            "func f() -> some Equatable { flag }",
            "typealias Flag = Bool; func f() -> Flag { flag }",
            "func f<T>() -> T { flag }",
            "func f() -> Int { count }",
            "func f() { return g() }",
            "func f() { g() }",
            "func f() { let x = flag! }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // A literal is FlipBooleanLiteral's, and an `if` or `switch` expression is left alone, branches included.
    func test_aLiteral_andAnIfOrSwitchExpression_areLeftAlone() throws {
        for code in [
            "func f() -> Bool { return true }",
            "func f() -> Bool { false }",
            "func f() -> Bool { (true) }",
            "func f() { let x: Bool = false }",
            "func f() -> Bool { if a { b } else { c } }",
            "func f() -> Bool { return switch a { case 1: b; default: c } }",
            "func f() { let x: Bool = if a { b } else { c } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        // A negated literal is a `!`, as a comparison of literals is a comparison.
        XCTAssertEqual(try values(in: "func f() { let x = !true }"), ["!true"])
    }

    // A closure that doesn't write its return type is mostly a predicate passed to `filter`, `sorted` or `contains`.
    func test_aClosureThatDoesntWriteItsReturnType_isLeftAlone() throws {
        for code in [
            "func f() { items.filter { $0 > 1 } }",
            "func f() { items.filter { x in x > 1 } }",
            "func f() { items.filter { x in return x > 1 } }",
            "func f() { items.sorted { (a: Int, b: Int) in a < b } }",
            "func f() { _ = #Predicate<Item> { $0.count > 1 } }",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
    }

    // An untyped closure's one expression is the closure's, even inside a function or getter that returns a Bool.
    func test_anUntypedClosuresOneExpression_isItsOwn_insideABoolFunctionOrGetter() throws {
        XCTAssertEqual(
            try values(in: "func f() -> Bool { items.contains { $0.isReady } }"),
            ["items.contains { $0.isReady }"]
        )
        XCTAssertEqual(
            try values(in: "struct S { var ok: Bool { items.contains { item in item.isReady } } }"),
            ["items.contains { item in item.isReady }"]
        )
    }

    // A binding counts at any scope, inside a closure that leaves its type to be inferred as well.
    func test_aBindingInsideAnUntypedClosure_counts() throws {
        XCTAssertEqual(try values(in: "func f() { items.forEach { x in let big = x > 1; use(big) } }"), ["x > 1"])
    }

    // A `return` is the innermost closure's or function's, whatever is around it.
    func test_aReturnInANestedClosureOrFunction_isItsOwn() throws {
        XCTAssertEqual(
            try values(in: """
            func f() -> Bool {
                let found = items.first { item in
                    return item.isReady
                }
                return found.isEmpty
            }
            """),
            ["found.isEmpty"]
        )
        XCTAssertEqual(
            try values(in: """
            func f() -> Bool {
                func count() -> Int { return items.count }
                return count() > 1
            }
            """),
            ["count() > 1"]
        )
        XCTAssertEqual(
            try values(in: """
            func f() -> Int {
                let isLarge = { (x: Int) -> Bool in x > limit }
                return isLarge(1) ? 1 : 0
            }
            """),
            ["x > limit"]
        )
    }

    // An initializer, a setter and an observer return nothing.
    func test_whatReturnsNothing_isLeftAlone() throws {
        XCTAssertEqual(try values(in: "struct S { init?() { if a < b { return nil }; return } }"), [])
        XCTAssertEqual(try values(in: "func f() { return }"), [])
        XCTAssertEqual(
            try values(in: "struct S { var x: Bool { get { flag } set { flag = newValue == other } } }"),
            ["flag"],
            "the getter's value, but not the setter's assignment"
        )
        XCTAssertEqual(
            try values(in: "struct S { var x: Bool = flag { didSet { if x { return } } } }"),
            ["flag"],
            "the property's value, but nothing in its observer"
        )
    }

    // A binding of one name: not `if let`, `guard let` or `case let`, a tuple's names, `_`, nor an assignment.
    func test_onlyABindingOfOneName_counts() throws {
        for code in [
            "func f() { if let x = a < b {} }",
            "func f() { guard let x = a < b else { return } }",
            "func f() { if case let x = a < b {} }",
            "func f() { let (x, y) = (a < b, c) }",
            "func f() { let _ = a < b }",
            "func f() { x = a < b }",
            "func f(x: Bool = a < b) {}",
        ] {
            XCTAssertEqual(try values(in: code), [], code)
        }
        XCTAssertEqual(try values(in: "func f() { let x = a < b, y = c, z = !d }"), ["a < b", "!d"])
    }
}
