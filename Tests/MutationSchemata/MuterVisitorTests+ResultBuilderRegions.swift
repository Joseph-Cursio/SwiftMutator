@testable import muterCore
import TestingExtensions

extension MuterVisitorTests {
    // In a builder, once the walk has lost the count, llvm-cov's counts can be stale, too high or too low, and it
    // keeps them as main does: below a region that reads 0, such as the code after an `if` that was never true, they
    // say nothing. In `halfTrue`, line 14 ran. In `neverElse` and `caseIf`, `n < -5000` never ran.
    func test_inAResultBuilder_countsTheWalkCantWorkOut_areKeptAsMainKeepsThem() throws {
        let source = try sourceCode(Self.countsTheWalkCantWorkOutCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 92, 15, 2, 2], [5, 8, 5, 10, 2], [5, 11, 7, 6, 2], [7, 6, 15, 2, 4], [8, 50, 15, 2, 4],
                    [8, 55, 10, 6, 2], [10, 6, 15, 2, 4], [11, 8, 11, 14, 4], [11, 15, 13, 6, 1], [13, 6, 15, 2, 2],
                ],
                [
                    [18, 93, 29, 2, 2], [19, 8, 19, 9, 2], [19, 10, 21, 6, 0], [21, 6, 29, 2, 0], [22, 50, 29, 2, 0],
                    [22, 55, 24, 6, 2], [24, 6, 29, 2, 0], [25, 8, 25, 10, 0], [25, 11, 27, 6, 2], [27, 6, 29, 2, 4],
                    [28, 37, 28, 40, 2], [28, 43, 28, 75, 2], [28, 65, 28, 68, 0], [28, 71, 28, 74, 2],
                ],
                [
                    [32, 74, 45, 2, 3], [33, 8, 33, 9, 3], [33, 10, 35, 6, 0], [35, 6, 45, 2, 0], [36, 12, 36, 13, 0],
                    [37, 5, 38, 41, 1], [38, 40, 38, 41, 1], [39, 5, 42, 10, 2], [40, 12, 40, 14, 2],
                    [40, 15, 42, 10, 2], [43, 6, 45, 2, 5], [44, 37, 44, 40, 3], [44, 43, 44, 75, 2],
                    [44, 65, 44, 68, 0], [44, 71, 44, 74, 2],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@11", "RelationalOperatorReplacement@11", "RelationalOperatorReplacement@14",
            "RelationalOperatorReplacement@14", "RelationalOperatorReplacement@22", "RelationalOperatorReplacement@22",
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@44",
            "RelationalOperatorReplacement@44", "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@8",
            "RemoveSideEffects@12", "RemoveSideEffects@14", "RemoveSideEffects@23", "RemoveSideEffects@26",
            "RemoveSideEffects@28", "RemoveSideEffects@38", "RemoveSideEffects@41", "RemoveSideEffects@44",
            "RemoveSideEffects@6", "RemoveSideEffects@9", "SwapTernary@28", "SwapTernary@44",
        ])
    }

    private static let countsTheWalkCantWorkOutCode = """
    import Foundation

    @ListBuilder
    public func halfTrue(_ sink: Sink, _ a: Bool, _ items: [Int], _ n: Int) throws -> [String] {
        if !a {
            sink.note("t")
        }
        for item in items where try sink.number(item) > 0 {
            sink.note("i")
        }
        if n == 1 {
            sink.note("one")
        }
        sink.note(String(n > 5))
    }

    @ListBuilder
    public func neverElse(_ sink: Sink, _ a: Bool, _ items: [Int], _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        for item in items where try sink.number(item) > 0 {
            sink.note("i")
        }
        if !a {
            sink.note("t")
        }
        sink.note(sink.wrap(n > -1000 ? "p" : sink.wrap(n < -5000 ? "q" : "r")))
    }

    @ListBuilder
    public func caseIf(_ sink: Sink, _ a: Bool, _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        switch n {
        case 1:
            sink.note(try sink.check("one"))
        default:
            if !a {
                sink.note("t")
            }
        }
        sink.note(sink.wrap(n > -1000 ? "p" : sink.wrap(n < -5000 ? "q" : "r")))
    }
    """

    // Below a region that reads 0, as after a builder's `if` that was never true, a builder's counts the walk can't
    // work out say nothing, in code that Swift counts directly and that ran too, as an `if`'s then-block or a closure:
    // after an `if` that was always true, they're too high there as well. So `n < -5000` never ran, in a ternary after
    // an operator the project declared, and in an `else` after a `for` whose `where` may throw, nor did `n > 50`, in a
    // closure that's such a ternary's `else`. One made there and called ran, as did its capture list: `n > -50` ran.
    // An implicit closure's count is its own, and so is that of the closure that's its body: `??`'s right-hand side
    // made one, so `n > 60` ran.
    func test_belowARegionThatReadsZero_aBuildersCountsInCodeThatRan_sayNothing() throws {
        let source = try sourceCode(Self.builderBelowARegionThatReadsZero)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[4, 46, 4, 59, 8]],
                [
                    [7, 69, 17, 2, 2], [8, 8, 8, 9, 2], [8, 10, 10, 6, 0], [10, 6, 17, 2, 0], [11, 8, 11, 10, 0],
                    [11, 11, 16, 6, 2], [12, 12, 12, 14, 2], [12, 15, 14, 10, 2], [14, 10, 16, 6, 4],
                    [15, 43, 15, 46, 2], [15, 49, 15, 81, 2], [15, 71, 15, 74, 0], [15, 77, 15, 80, 2],
                    [16, 6, 17, 2, 8],
                ],
                [[19, 71, 19, 84, 2]],
                [[22, 71, 32, 2, 2], [23, 8, 23, 9, 2], [23, 10, 25, 6, 0], [25, 6, 32, 2, 0]],
                [
                    [26, 11, 31, 6, 2], [27, 12, 27, 14, 2], [27, 15, 29, 10, 2], [29, 10, 31, 6, 4],
                    [30, 43, 30, 46, 2], [30, 49, 30, 81, 2], [30, 71, 30, 74, 0], [30, 77, 30, 80, 2],
                ],
                [
                    [35, 93, 52, 2, 2], [36, 8, 36, 9, 2], [36, 10, 38, 6, 0], [38, 6, 52, 2, 0], [39, 8, 39, 10, 0],
                    [39, 11, 51, 6, 2], [40, 48, 51, 6, 2], [40, 49, 42, 10, 2], [42, 10, 51, 6, 2],
                    [43, 12, 43, 14, 2], [43, 15, 45, 10, 2], [45, 10, 51, 6, 4], [46, 12, 46, 21, 4],
                    [46, 22, 48, 10, 2], [48, 16, 50, 10, 2], [49, 45, 49, 48, 0], [49, 51, 49, 54, 2],
                    [51, 6, 52, 2, 8],
                ],
                [
                    [55, 70, 65, 2, 2], [56, 8, 56, 9, 2], [56, 10, 58, 6, 0], [58, 6, 65, 2, 0], [59, 8, 59, 10, 0],
                    [59, 11, 64, 6, 2], [60, 12, 60, 14, 2], [60, 15, 62, 10, 2], [62, 10, 64, 6, 4],
                    [63, 37, 63, 45, 2], [63, 48, 63, 69, 2], [64, 6, 65, 2, 8],
                ],
                [[63, 37, 63, 45, 2]],
                [[63, 48, 63, 69, 0]],
                [
                    [68, 75, 78, 2, 2], [69, 8, 69, 9, 2], [69, 10, 71, 6, 0], [71, 6, 78, 2, 0], [72, 8, 72, 10, 0],
                    [72, 11, 77, 6, 2], [73, 12, 73, 14, 2], [73, 15, 75, 10, 2], [75, 10, 77, 6, 4],
                    [76, 37, 76, 45, 0], [76, 48, 76, 70, 4], [77, 6, 78, 2, 8],
                ],
                [[76, 37, 76, 45, 0]],
                [[76, 48, 76, 70, 2]],
                [[80, 44, 80, 54, 2]],
                [[83, 100, 88, 2, 2], [84, 8, 84, 9, 2], [84, 10, 86, 6, 0], [86, 6, 88, 2, 0]],
                [[87, 25, 87, 46, 2]],
                [[87, 25, 87, 46, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), Self.builderMutantsBelowARegionReadingZero)
    }

    private static let builderMutantsBelowARegionReadingZero = [
        "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@40",
        "RelationalOperatorReplacement@40", "RelationalOperatorReplacement@46", "RelationalOperatorReplacement@46",
        "RelationalOperatorReplacement@76", "RelationalOperatorReplacement@76", "RelationalOperatorReplacement@87",
        "RelationalOperatorReplacement@87", "RemoveSideEffects@13", "RemoveSideEffects@15", "RemoveSideEffects@28",
        "RemoveSideEffects@30", "RemoveSideEffects@31", "RemoveSideEffects@41", "RemoveSideEffects@44",
        "RemoveSideEffects@47", "RemoveSideEffects@61", "RemoveSideEffects@63", "RemoveSideEffects@74",
        "RemoveSideEffects@76", "RemoveSideEffects@87", "SwapTernary@15", "SwapTernary@30", "SwapTernary@63",
        "SwapTernary@76",
    ]

    private static let builderBelowARegionThatReadsZero = """
    import Foundation

    infix operator <~>: ComparisonPrecedence
    public func <~> (lhs: Int, rhs: Int) -> Bool { lhs > rhs }

    @ListBuilder
    public func declared(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if a {
            sink.note("a")
        }
        if !a {
            if !a {
                sink.note("t")
            }
            sink.note(sink.wrap(n <~> -1000 ? "p" : sink.wrap(n < -5000 ? "q" : "r")))
        }
    }

    public func group(@ListBuilder _ content: () -> [String]) -> [String] { content() }

    @ListBuilder
    public func inAClosure(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if a {
            sink.note("a")
        }
        group {
            if !a {
                sink.note("t")
            }
            sink.note(sink.wrap(n <~> -1000 ? "p" : sink.wrap(n < -5000 ? "q" : "r")))
        }
    }

    @ListBuilder
    public func neverElse(_ sink: Sink, _ a: Bool, _ items: [Int], _ n: Int) throws -> [String] {
        if a {
            sink.note("a")
        }
        if !a {
            for i in items where try sink.ok(i < 0) {
                sink.note("i")
            }
            if !a {
                sink.note("t")
            }
            if n > -1000 {
                sink.note("u")
            } else {
                sink.note(sink.wrap(n < -5000 ? "x" : "y"))
            }
        }
    }

    @ListBuilder
    public func staleElse(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if a {
            sink.note("a")
        }
        if !a {
            if !a {
                sink.note("t")
            }
            sink.note(String((n <~> 0 ? { true } : { [v = n > 50] in v })()))
        }
    }

    @ListBuilder
    public func staleElseTaken(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if a {
            sink.note("a")
        }
        if !a {
            if !a {
                sink.note("t")
            }
            sink.note(String((n <~> 0 ? { true } : { [v = n > -50] in v })()))
        }
    }

    func made(_ closure: () -> Bool) -> String { "made" }

    @ListBuilder
    public func coalescedBelowNever(_ sink: Sink, _ a: Bool, _ n: Int, _ f: (() -> Bool)?) -> [String] {
        if a {
            sink.note("a")
        }
        sink.note(made(f ?? { [v = n > 60] in v }))
    }
    """

    func test_removeSideEffects_inAResultBuilderNoTestCalled_isLeftOut() throws {
        let source = try sourceCode("""
        import Foundation

        @ListBuilder
        public func neverCalled(_ sink: Sink) -> [String] {
            sink.note("one")
            sink.note("two")
        }

        @ListBuilder
        public func called(_ sink: Sink) -> [String] {
            sink.note("three")
            sink.note("four")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [.make(lineStart: 4, columnStart: 51, lineEnd: 7, columnEnd: 2)]
        )

        XCTAssertEqual(mutants(in: mappings), ["RemoveSideEffects@11", "RemoveSideEffects@12"])
    }
}
