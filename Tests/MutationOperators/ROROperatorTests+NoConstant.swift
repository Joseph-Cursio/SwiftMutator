import TestingExtensions
import XCTest

extension ROROperatorTests {
    // A comparison whose value is thrown away is an overload with side effects, as Nimble's `expect(x) == 1`: a
    // literal there would be an unused value that tests nothing. The swap still changes what it is called with.
    func test_aComparisonThatIsAStatement_getsOnlyItsSwap() throws {
        XCTAssertEqual(try changes(in: "func f() { expect(x) == 1 }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { expect(x) != 1 }"), ["!= → =="])
        XCTAssertEqual(try changes(in: "func f() { expect(x) < 1 }"), ["< → !="])
        XCTAssertEqual(try changes(in: "func f() throws { try expect(x) >= 1 }"), [">= → =="])
        XCTAssertEqual(try changes(in: "func f() { work(); expect(x) == 1 }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() -> Void { expect(x) == 1 }"), ["== → !="])
        XCTAssertEqual(try changes(in: "struct S { init() { expect(x) == 1 } }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { if c { expect(x) == 1 } }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { switch c { case 1: expect(x) == 1; default: break } }"), [
            "== → !=",
        ])
        XCTAssertEqual(try changes(in: "expect(x) == 1"), ["== → !="])
    }

    // The one statement of a body that gives its value is that value: a closure's, whatever its type, as it is mostly
    // a predicate, a getter's, a function's that writes its return type, and a branch's of an `if` or `switch` that
    // is a value.
    func test_theOneStatementOfABodyThatGivesItsValue_getsItsConstants() throws {
        for code in [
            "func f() -> Bool { a == b }",
            "func f() { items.filter { _ in a == b } }",
            "func f() { items.filter { (x: Int) -> Bool in a == b } }",
            "struct S { var ok: Bool { a == b } }",
            "struct S { var ok: Bool { get { a == b } } }",
            "struct S { subscript(i: Int) -> Bool { a == b } }",
            "func f() { let v = if c { a == b } else { d } }",
            "func f() { let v = if c { d } else if e { a == b } else { d } }",
            "func f() -> Bool { if c { a == b } else { d } }",
            "func f() { let v = switch c { case 1: a == b; default: d } }",
        ] {
            XCTAssertEqual(try changes(in: code), ["a == b → true", "a == b → false"], code)
        }
    }

    // `while true` loops until the time limit, and the score counts such a timeout as a survivor, so a comparison
    // that decides a loop's condition gets no constant that makes it always true: its swap or its other constant is
    // left, and is wrong only where the negation is too.
    func test_aComparisonThatDecidesALoop_getsNoConstantThatKeepsItGoing() throws {
        XCTAssertEqual(try changes(in: "func f() { while a <= b {} }"), ["<= → =="])
        XCTAssertEqual(try changes(in: "func f() { while (a >= b) {} }"), [">= → =="])
        XCTAssertEqual(try changes(in: "func f() { while a != b {} }"), ["a != b → false"])
        XCTAssertEqual(try changes(in: "func f() { repeat {} while a == b }"), ["a == b → false"])
        XCTAssertEqual(try changes(in: "func f() { repeat {} while (a <= b) }"), ["<= → =="])
        XCTAssertEqual(try changes(in: "func f() throws { while try a == load() {} }"), ["try a == load() → false"])
        XCTAssertEqual(try changes(in: "func f() { while c || a == b {} }"), ["a == b → false"])
        XCTAssertEqual(try changes(in: "func f() { while !(a == b) {} }"), ["a == b → true"])
        XCTAssertEqual(try changes(in: "func f() { while !(a < b) {} }"), ["< → !="])
        // `false` ends the loop.
        XCTAssertEqual(try changes(in: "func f() { while a < b {} }"), ["< → !=", "a < b → false"])
        // The rest of the condition can still end the loop, and an `if` or `guard` doesn't loop.
        for code in [
            "func f() { while a == b, c {} }",
            "func f() { while a == b && c {} }",
            "func f() { while (a == b) && c {} }",
            "func f() { if a == b {} }",
            "func f() { guard a == b else { return } }",
            "func f() { while c { let v = a == b } }",
        ] {
            XCTAssertEqual(try changes(in: code), ["a == b → true", "a == b → false"], code)
        }
    }

    // An operator the standard table doesn't hold has no known precedence, so the comparison's extent isn't known.
    // Its swap is safe: `==` gets the swap it got before.
    func test_aSequenceTheStandardTableCantFold_getsOnlyTheSwap() throws {
        XCTAssertEqual(try changes(in: "func f() -> Bool { a <> b == c }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a <> b < c }"), ["< → !="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { a < b == c }"), ["< → !=", "== → !="])
        XCTAssertEqual(try changes(in: "func f() -> Bool { (a <> b) == c }"), [
            "(a <> b) == c → true", "(a <> b) == c → false",
        ])
    }

    // A closure that names no parameters takes as many as the highest `$` argument it uses says, so `{ $0 > 1 }` as
    // `{ false }` takes none, which doesn't compile where one is passed.
    func test_aComparisonHoldingAClosuresOnlyUseOfItsHighestArgument_getsOnlyItsSwap() throws {
        XCTAssertEqual(try changes(in: "func f() { items.filter { $0 > 1 } }"), ["> → !="])
        XCTAssertEqual(try changes(in: "func f() { items.sorted { $0 < $1 } }"), ["< → !="])
        XCTAssertEqual(try changes(in: "func f() { items.filter { $0 == 1 } }"), ["== → !="])
        XCTAssertEqual(try changes(in: "func f() { items.first { $0.count == 1 && $0.isReady } }"), [
            "$0.count == 1 → true", "$0.count == 1 → false",
        ])
        XCTAssertEqual(try changes(in: "func f() { pairs.sorted { $0.a < $1.a || $1.b > 2 } }"), [
            "< → !=", "$0.a < $1.a → false", "> → !=", "$1.b > 2 → false",
        ])
        XCTAssertEqual(try changes(in: "func f() { lists.filter { $0.filter { $0 > 1 }.count == 2 } }"), [
            "> → !=", "== → !=",
        ])
        XCTAssertEqual(try changes(in: "func f() { items.filter { x in x > 1 } }"), ["> → !=", "x > 1 → false"])
    }
}
