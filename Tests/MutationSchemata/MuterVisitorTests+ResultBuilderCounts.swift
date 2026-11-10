@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MuterVisitorTests {
    // In a builder, the count after a `try` is the wrong count before it less the times it threw, which is negative
    // and loses whether it threw every time. `once` threw for 1 of 3 calls, and "big" ran after it; `each` threw for
    // 1 of 2, and the closure after it ran; `always` threw for both, and nothing after it ran. The `else` in `ladder`,
    // after a condition that may throw, never ran either.
    func test_inAResultBuilder_theCodeAfterATryThatAlwaysThrew_isLeftOut() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode(Self.codeAfterATryThatAlwaysThrew)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 75, 10, 2, 3], [5, 8, 5, 15, 3], [5, 16, 7, 6, 0], [7, 6, 10, 2, 0], [8, 30, 10, 2, negative],
                    [9, 23, 9, 28, 1], [9, 31, 9, 38, negative],
                ],
                [
                    [13, 63, 19, 2, 2], [14, 8, 14, 15, 2], [14, 16, 16, 6, 0], [16, 6, 19, 2, 0],
                    [17, 30, 19, 2, negative], [18, 23, 18, 28, 0], [18, 31, 18, 38, negative],
                ],
                [
                    [22, 78, 28, 2, 2], [23, 8, 23, 18, 2], [23, 19, 25, 6, 0], [25, 6, 28, 2, 0],
                    [26, 30, 28, 2, negative],
                ],
                [[27, 22, 27, 36, 2]],
                [
                    [31, 74, 42, 2, 3], [32, 8, 32, 9, 3], [32, 10, 34, 6, 0], [34, 6, 42, 2, 0], [35, 8, 35, 15, 0],
                    [35, 16, 37, 6, 1], [37, 15, 37, 33, negative], [37, 33, 41, 6, negative], [37, 34, 39, 6, 2],
                    [39, 12, 41, 6, negative], [40, 28, 40, 35, 0], [40, 38, 40, 45, negative], [41, 6, 42, 2, 0],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@14", "RelationalOperatorReplacement@35", "RelationalOperatorReplacement@37",
            "RelationalOperatorReplacement@5", "RelationalOperatorReplacement@9", "RemoveSideEffects@17",
            "RemoveSideEffects@26", "RemoveSideEffects@27", "RemoveSideEffects@36", "RemoveSideEffects@38",
            "RemoveSideEffects@8", "RemoveSideEffects@9", "SwapTernary@9",
        ])
    }

    private static let codeAfterATryThatAlwaysThrew = """
    import Foundation

    @ListBuilder
    public func once(_ sink: Sink, _ fail: Bool, _ n: Int) throws -> [String] {
        if n > 100 {
            sink.note("huge")
        }
        try sink.check("r", fail)
        sink.note(n > 2 ? "big" : "small")
    }

    @ListBuilder
    public func always(_ sink: Sink, _ n: Int) throws -> [String] {
        if n > 100 {
            sink.note("huge")
        }
        try sink.check("r", true)
        sink.note(n > 2 ? "big" : "small")
    }

    @ListBuilder
    public func each(_ sink: Sink, _ fail: Bool, _ xs: [Int]) throws -> [String] {
        if xs.isEmpty {
            sink.note("none")
        }
        try sink.check("r", fail)
        sink.note(xs.map { String($0) }.joined())
    }

    @ListBuilder
    public func ladder(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        if n > 100 {
            sink.note("huge")
        } else if try sink.ok(n < 0) {
            sink.note("r")
        } else {
            sink.note(n == 3 ? "three" : "other")
        }
    }
    """

    // In a builder, a ternary's branch with a `try` that threw for `label(sink, false, 9)`, after an `if` never true:
    // the region after the call is negative, and the one holding it 0.
    func test_inAResultBuilder_aTernaryBranchThatThrew_afterAnIfNeverTrue_isWalked() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
        import Foundation

        @ListBuilder
        public func label(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
            if a {
                sink.note("a")
            }
            sink.note(n > 0 ? try sink.check("p", n == 9) : "np")
            sink.note(n > 4 ? "x" : "y")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 73, 10, 2, 3], [5, 8, 5, 9, 3], [5, 10, 7, 6, 0], [7, 6, 10, 2, 0], [8, 23, 8, 50, 3],
                    [8, 50, 10, 2, negative], [8, 53, 8, 57, negative], [9, 23, 9, 26, 1], [9, 29, 9, 32, negative],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@8",
            "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@9", "RelationalOperatorReplacement@9",
            "RemoveSideEffects@8", "RemoveSideEffects@9", "SwapTernary@8", "SwapTernary@9",
        ])
    }

    // Swift counts the code in an `if`'s second condition as the code before the `if`, less the times a call there
    // threw. In a builder, after an `if` that was never true, line 13 ran in `secondTry(sink, false, 1)` and
    // `(sink, false, 2)`, and in `secondTernary`, after one that was always true too, `n < -9` never ran.
    func test_inAResultBuilder_anIfsSecondCondition_isWalkedFromTheCountBeforeTheIf() throws {
        let source = try sourceCode(Self.ifsSecondConditionInABuilder)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 77, 14, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 14, 2, 0], [8, 8, 8, 10, 0],
                    [8, 30, 14, 2, 0], [8, 38, 10, 6, 0], [10, 12, 12, 6, 0], [13, 34, 13, 40, 0], [13, 43, 13, 48, 0],
                ],
                [
                    [17, 74, 30, 2, 2], [18, 8, 18, 9, 2], [18, 10, 20, 6, 0], [20, 6, 30, 2, 0], [21, 8, 21, 10, 0],
                    [21, 11, 23, 6, 2], [23, 6, 30, 2, 4], [24, 8, 24, 10, 4], [25, 11, 25, 15, 2], [26, 11, 26, 17, 2],
                    [26, 18, 28, 6, 2], [28, 6, 30, 2, 4],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@24",
            "RelationalOperatorReplacement@24", "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@8",
            "RemoveSideEffects@11", "RemoveSideEffects@13", "RemoveSideEffects@22", "RemoveSideEffects@27",
            "RemoveSideEffects@29", "SwapTernary@13", "SwapTernary@26",
        ])
    }

    private static let ifsSecondConditionInABuilder = """
    import Foundation

    @ListBuilder
    public func secondTry(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        if !a, try sink.number(n) >= 100 {
            sink.note("big")
        } else {
            sink.note(sink.wrap("small"))
        }
        sink.note(sink.wrap(n > 50 ? "huge" : "end"))
    }

    @ListBuilder
    public func secondTernary(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if a {
            sink.note("a")
        }
        if !a {
            sink.note("t")
        }
        if !a, n > 0
            ? true
            : n < -9 {
            sink.note("u")
        }
        sink.note(sink.wrap("end"))
    }
    """

    // In a builder, below a count worked out again, one the walk can't work out says nothing, though it's some: after
    // an `if` that was always true, Swift's count is too high. In `maybe(sink, false, 1)` and `(sink, false, 2)`, the
    // `try?`'s second call's second branch never ran, but `n > 0`, before the first branch, which ran, did.
    func test_inAResultBuilder_aCountTheWalkCantWorkOut_belowOneWorkedOutAgain_saysNothing() throws {
        let source = try sourceCode("""
        import Foundation

        @ListBuilder
        public func maybe(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
            if a {
                sink.note("a")
            }
            if !a {
                sink.note("t")
            }
            sink.note((try? sink.check("x") + sink.check(n > 0 ? "p" : sink.wrap(
                n < -5 ? "q" : "r"
            ))) ?? "none")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 66, 14, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 14, 2, 0], [8, 8, 8, 10, 0],
                    [8, 11, 10, 6, 2], [10, 6, 14, 2, 4], [11, 36, 13, 7, 4], [11, 58, 11, 61, 2], [11, 64, 13, 6, 2],
                    [12, 18, 12, 21, 0], [12, 24, 12, 27, 2],
                ],
                [[13, 12, 13, 18, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@11", "RelationalOperatorReplacement@11", "RemoveSideEffects@13",
            "RemoveSideEffects@9", "SwapTernary@13",
        ])
    }

    // In a builder, after an `if` that was always true, Swift's counts are as much too high as the walk lowers the
    // count after the `if`. One it can't work out below that, but higher, ran: after a `for` loop whose `where` may
    // throw, in a `try` with two calls, and after a call in an `if`'s condition. Swift counts the code after a `switch`
    // from its cases, and that in a loop's body from the body's own count. Each line here ran in the tests but line 42,
    // the `then` of firstCondition's `if`.
    func test_inAResultBuilder_aCountHigherThanItCanBeTooHigh_ran() throws {
        let source = try sourceCode(Self.countTooHighInABuilder)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 79, 15, 2, 2], [5, 8, 5, 10, 2], [5, 11, 7, 6, 2], [7, 6, 15, 2, 4], [8, 12, 8, 13, 4],
                    [9, 5, 10, 41, 1], [10, 40, 10, 41, 1], [11, 5, 12, 43, 1], [12, 42, 12, 43, 1], [13, 6, 15, 2, 2],
                ],
                [
                    [18, 94, 26, 2, 2], [19, 8, 19, 10, 2], [19, 11, 21, 6, 2], [21, 6, 26, 2, 4], [22, 50, 26, 2, 3],
                    [22, 55, 24, 6, 3], [24, 6, 26, 2, 3],
                ],
                [
                    [29, 74, 34, 2, 2], [30, 8, 30, 10, 2], [30, 11, 32, 6, 2], [32, 6, 34, 2, 4], [33, 34, 34, 2, 4],
                    [33, 56, 33, 59, 0], [33, 62, 33, 90, 4], [33, 80, 33, 83, 0], [33, 86, 33, 89, 4],
                    [33, 91, 34, 2, 4],
                ],
                [
                    [37, 82, 46, 2, 2], [38, 8, 38, 10, 2], [38, 11, 40, 6, 2], [40, 6, 46, 2, 4], [41, 8, 41, 33, 4],
                    [41, 26, 41, 33, 4], [41, 33, 46, 2, 4], [41, 34, 43, 6, 0], [43, 12, 45, 6, 4],
                ],
                [
                    [49, 74, 56, 2, 2], [50, 8, 50, 10, 2], [50, 11, 52, 6, 2], [52, 6, 56, 2, 4], [53, 20, 55, 6, 2],
                    [54, 40, 54, 97, 2], [54, 62, 54, 65, 0], [54, 68, 54, 96, 2], [54, 86, 54, 89, 0],
                    [54, 92, 54, 95, 2], [55, 6, 56, 2, 4],
                ],
                [[54, 102, 54, 104, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@14", "RelationalOperatorReplacement@14", "RelationalOperatorReplacement@22",
            "RelationalOperatorReplacement@22", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@33", "RelationalOperatorReplacement@33", "RelationalOperatorReplacement@33",
            "RelationalOperatorReplacement@33", "RelationalOperatorReplacement@41", "RelationalOperatorReplacement@41",
            "RelationalOperatorReplacement@54", "RelationalOperatorReplacement@54", "RelationalOperatorReplacement@54",
            "RelationalOperatorReplacement@54", "RemoveSideEffects@10", "RemoveSideEffects@12", "RemoveSideEffects@14",
            "RemoveSideEffects@20", "RemoveSideEffects@23", "RemoveSideEffects@25", "RemoveSideEffects@31",
            "RemoveSideEffects@33", "RemoveSideEffects@39", "RemoveSideEffects@44", "RemoveSideEffects@51",
            "RemoveSideEffects@54", "RemoveSideEffects@6", "SwapTernary@33", "SwapTernary@33", "SwapTernary@54",
            "SwapTernary@54",
        ])
    }

    private static let countTooHighInABuilder = """
    import Foundation

    @ListBuilder
    public func afterSwitch(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if !a {
            sink.note("t")
        }
        switch n {
        case 1:
            sink.note(try sink.check("one"))
        default:
            sink.note(try sink.check("other"))
        }
        sink.note(String(n > 5))
    }

    @ListBuilder
    public func afterWhere(_ sink: Sink, _ a: Bool, _ items: [Int], _ n: Int) throws -> [String] {
        if !a {
            sink.note("t")
        }
        for item in items where try sink.number(item) > 0 {
            sink.note("i")
        }
        sink.note(String(n > 5))
    }

    @ListBuilder
    public func inATry(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if !a {
            sink.note("t")
        }
        sink.note(try sink.check("x") + sink.check(n > 5 ? "y" : sink.wrap(n < 3 ? "z" : "w")))
    }

    @ListBuilder
    public func firstCondition(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if !a {
            sink.note("t")
        }
        if try sink.number(n) >= 100 {
            sink.note("big")
        } else {
            sink.note("small")
        }
    }

    @ListBuilder
    public func inALoop(_ sink: Sink, _ a: Bool, _ items: [Int]) -> [String] {
        if !a {
            sink.note("t")
        }
        for i in items {
            sink.note((try? sink.check("x") + sink.check(i > 5 ? "y" : sink.wrap(i < 3 ? "z" : "w"))) ?? "")
        }
    }
    """
}
