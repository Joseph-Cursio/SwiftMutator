@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MuterVisitorTests {
    // In a result builder, llvm-cov counts the code after an `if` that was never true as never run, and gives an
    // `else` that never ran a count. These are its regions when the tests call `pick(sink, false, true, 3)` and
    // `pick(sink, false, true, 1)`, so the code after the first `if` and the `then` of the second ran, and the `else`
    // didn't.
    func test_inAResultBuilder_theCodeThatRan_isKept_andTheCodeThatDidNot_isLeftOut() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
        import Foundation

        @ListBuilder
        public func pick(_ sink: Sink, _ a: Bool, _ b: Bool, _ n: Int) -> [String] {
            if a {
                sink.note("a")
            }
            if b {
                sink.note(n > 2 ? "big" : "small")
            } else {
                sink.note(n > 5 ? "huge" : "tiny")
            }
            sink.note(n > 1 ? "some" : "none")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 76, 14, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 14, 2, 0], [8, 8, 8, 9, 0],
                    [8, 10, 10, 6, 2], [9, 27, 9, 32, 1], [9, 35, 9, 42, 1], [10, 12, 12, 6, negative],
                    [11, 27, 11, 33, 0], [11, 36, 11, 42, negative], [13, 23, 13, 29, 1], [13, 32, 13, 38, negative],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@9", "RemoveSideEffects@13",
            "RemoveSideEffects@9", "SwapTernary@13", "SwapTernary@9",
        ])
    }

    // A function marked with a builder, and a closure passed to a builder parameter, which looks like any other. These
    // are llvm-cov's regions when the tests only call `built(sink, false)` and `each(sink, [1, 2])`.
    func test_inAResultBuilderFunctionOrClosure_theCodeAfterAnIfThatWasNeverTrue_isKept() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
        import Foundation

        @ListBuilder
        public func built(_ sink: Sink, _ flag: Bool) -> [String] {
            if flag {
                sink.note("flag")
            }
            sink.note("after")
        }

        public func each(_ sink: Sink, _ items: [Int]) -> [String] {
            make {
                for item in items {
                    if item > 100 {
                        sink.note("huge")
                    }
                    sink.note("item")
                }
            }
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[4, 59, 9, 2, 1], [5, 8, 5, 12, 1], [5, 13, 7, 6, 0], [7, 6, 9, 2, 0]],
                [[11, 60, 20, 2, 1]],
                [
                    [12, 10, 19, 6, 1], [13, 27, 18, 10, 2], [14, 16, 14, 26, 2], [14, 27, 16, 14, 0],
                    [16, 14, 18, 10, 0], [18, 10, 19, 6, negative],
                ],
            ])
        )

        XCTAssertEqual(
            Set(mutants(in: mappings)),
            ["RemoveSideEffects@8", "RelationalOperatorReplacement@14", "RemoveSideEffects@17"]
        )
    }

    // A property's `get` takes the builder from the property. The regions are llvm-cov's for `items` of `[1, 2]`.
    func test_inAResultBuilderProperty_theCodeAfterAnIfThatWasNeverTrue_isKept() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
        import Foundation

        public struct Rows {
            let sink: Sink
            let items: [Int]

            @ListBuilder
            public var rows: [String] {
                get {
                    for item in items {
                        if item > 100 {
                            sink.note("huge")
                        }
                        sink.note("item")
                    }
                }
            }
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [9, 13, 16, 10, 1], [10, 31, 15, 14, 2], [11, 20, 11, 30, 2], [11, 31, 13, 18, 0],
                    [13, 18, 15, 14, 0], [15, 14, 16, 10, negative],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings), [
            "RelationalOperatorReplacement@11", "RelationalOperatorReplacement@11", "RemoveSideEffects@14",
        ])
    }

    // A builder's cases in a `#if`, each ending in an `if` that was never true, so llvm-cov counts the code after the
    // `switch` as never run, and a builder with a `try`, which never threw. The tests call `kinds` with 0, 1 and 9, and
    // `risky(sink, false, 3)` and `risky(sink, false, 1)`: every condition and every line after the `switch` and the
    // `try` ran.
    func test_inAResultBuilder_casesInAnIfConfig_andATry_areWalked() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode(Self.builderCasesInAnIfConfigCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 55, 22, 2, 3], [5, 12, 5, 13, 3], [6, 5, 9, 10, 1], [7, 12, 7, 19, 1], [7, 20, 9, 10, 0],
                    [10, 5, 10, 14, 0, 2], [11, 5, 14, 10, 1], [12, 12, 12, 19, 1], [12, 20, 14, 10, 0],
                    [15, 5, 15, 11, 0, 2], [16, 5, 19, 10, 1], [17, 12, 17, 19, 1], [17, 20, 19, 10, 0],
                    [20, 6, 22, 2, 0], [21, 23, 21, 28, 1], [21, 31, 21, 38, negative],
                ],
                [
                    [25, 73, 31, 2, 2], [26, 8, 26, 9, 2], [26, 10, 28, 6, 0], [28, 6, 31, 2, 0], [29, 24, 31, 2, 0],
                    [30, 23, 30, 28, 1], [30, 31, 30, 38, negative],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@12", "RelationalOperatorReplacement@17", "RelationalOperatorReplacement@21",
            "RelationalOperatorReplacement@30", "RelationalOperatorReplacement@7", "RemoveSideEffects@21",
            "RemoveSideEffects@29", "RemoveSideEffects@30", "SwapTernary@21", "SwapTernary@30",
        ])
    }

    private static let builderCasesInAnIfConfigCode = """
    import Foundation

    @ListBuilder
    public func kinds(_ sink: Sink, _ n: Int) -> [String] {
        switch n {
        case 0:
            if n > 100 {
                sink.note("huge")
            }
        #if DEBUG
        case 1:
            if n > 100 {
                sink.note("big one")
            }
        #endif
        default:
            if n > 100 {
                sink.note("far")
            }
        }
        sink.note(n > 2 ? "big" : "small")
    }

    @ListBuilder
    public func risky(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        try sink.check("r")
        sink.note(n > 2 ? "big" : "small")
    }
    """

    // In a builder, after an `if` that was never true: a `try!` call starts a region of its own too, a `switch`'s
    // subject throwing doesn't change the count after it, and the code in a `try` runs as often as the `try` when only
    // its last call can throw. The tests call `forced(sink, false)`, `kind(sink, 0)` and `argument(sink, false, 1)` and
    // `argument(sink, false, 0)`, each twice or once each.
    func test_inAResultBuilder_aTryBang_aSwitchOnATry_andATernaryInATry_areWalked() throws {
        let source = try sourceCode(Self.builderTriesCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[4, 57, 10, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 10, 2, 0], [8, 25, 10, 2, 0]],
                [
                    [13, 61, 23, 2, 2], [14, 12, 14, 30, 2], [14, 30, 23, 2, 2], [15, 5, 18, 10, 2],
                    [16, 12, 16, 19, 2], [16, 20, 18, 10, 0], [19, 5, 20, 27, 0], [21, 6, 23, 2, 0],
                ],
                [
                    [26, 76, 31, 2, 2], [27, 8, 27, 9, 2], [27, 10, 29, 6, 0], [29, 6, 31, 2, 0], [30, 28, 30, 33, 0],
                    [30, 36, 30, 71, 0], [30, 55, 30, 60, 0], [30, 63, 30, 70, 0], [30, 72, 31, 2, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@16", "RelationalOperatorReplacement@16", "RelationalOperatorReplacement@30",
            "RelationalOperatorReplacement@30", "RelationalOperatorReplacement@30", "RelationalOperatorReplacement@30",
            "RemoveSideEffects@22", "RemoveSideEffects@30", "RemoveSideEffects@8", "RemoveSideEffects@9",
            "SwapTernary@30", "SwapTernary@30",
        ])
    }

    private static let builderTriesCode = """
    import Foundation

    @ListBuilder
    public func forced(_ sink: Sink, _ a: Bool) -> [String] {
        if a {
            sink.note("a")
        }
        try! sink.check("r")
        sink.note("end")
    }

    @ListBuilder
    public func kind(_ sink: Sink, _ n: Int) throws -> [String] {
        switch try sink.number(n) {
        case 0:
            if n > 100 {
                sink.note("huge")
            }
        default:
            sink.note("other")
        }
        sink.note("end")
    }

    @ListBuilder
    public func argument(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        try sink.check(n > 2 ? "big" : sink.note(n < -5 ? "neg" : "small"))
    }
    """

    // In a builder, the counts around a call in a ternary's branch can both be negative, which loses what it threw and
    // every count after it. A region that holds code Swift counts directly that ran still ran: line 12's "big". The
    // tests call `later` with (true, false, 3), (false, false, 1), and (false, true, 3), which throws.
    func test_inAResultBuilder_codeThatHoldsCodeThatRan_ran() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
        import Foundation

        @ListBuilder
        public func later(_ sink: Sink, _ a: Bool, _ fail: Bool, _ n: Int) throws -> [String] {
            if n > 100 {
                sink.note("h")
            }
            sink.note(a ? "y" : sink.wrap(try sink.check("x", fail)))
            if n > 50 {
                sink.note("fifty")
            }
            sink.note(n > 2 ? "big" : "small")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 87, 13, 2, 3], [5, 8, 5, 15, 3], [5, 16, 7, 6, 0], [7, 6, 13, 2, 0], [8, 19, 8, 22, 1],
                    [8, 25, 8, 61, negative], [8, 60, 8, 61, negative], [8, 61, 13, 2, negative],
                    [9, 8, 9, 14, negative], [9, 15, 11, 6, 0], [11, 6, 13, 2, 0], [12, 23, 12, 28, 1],
                    [12, 31, 12, 38, negative],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@5", "RemoveSideEffects@8", "SwapTernary@8",
            "RelationalOperatorReplacement@9", "RemoveSideEffects@12", "RelationalOperatorReplacement@12",
            "SwapTernary@12",
        ])
    }
}
