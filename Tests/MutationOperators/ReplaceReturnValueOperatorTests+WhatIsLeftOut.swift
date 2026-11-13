import XCTest

extension ReplaceReturnValueOperatorTests {
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
}
