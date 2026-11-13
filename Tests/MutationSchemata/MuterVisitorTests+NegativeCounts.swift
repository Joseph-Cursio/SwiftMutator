@testable import muterCore
import TestingExtensions

extension MuterVisitorTests {
    // A negative count Swift gets wrong is worked out again, but a negative count in it that the walk can't work out
    // only repeats it, and counts as run, as llvm-cov's own negatives do: `v < 5` in the `case` that
    // `classify(150, ...)` entered, and the line after the `try` once `skip(4, &log)` left its `repeat` by `continue`.
    func test_aNegativeCountBelowANegativeCountWorkedOutAgain_ran() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode(Self.negativeCountBelowNegativeCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 37, 6, 2, 4], [4, 8, 4, 13, 4], [4, 14, 4, 29, 2], [4, 29, 5, 13, 2]],
                [
                    [8, 70, 19, 2, 3], [9, 12, 9, 13, 3], [10, 5, 15, 17, 1], [10, 35, 15, 17, negative],
                    [12, 32, 12, 37, 0], [12, 40, 12, 45, negative], [12, 47, 14, 10, 2], [14, 10, 15, 17, negative],
                    [16, 5, 17, 18, 0],
                ],
                [
                    [21, 66, 30, 2, 1], [23, 12, 26, 6, 4], [25, 12, 25, 22, 4], [25, 23, 25, 35, 2],
                    [25, 35, 26, 6, 2], [26, 6, 29, 17, negative], [26, 13, 26, 18, 4], [27, 26, 29, 17, negative],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@12",
            "RelationalOperatorReplacement@12", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@26", "RelationalOperatorReplacement@26", "RelationalOperatorReplacement@29",
            "RelationalOperatorReplacement@29", "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4",
            "RemoveSideEffects@28", "SwapTernary@12",
        ])
    }

    private static let negativeCountBelowNegativeCode = """
    import Foundation

    func weight(_ x: Int) throws -> Int {
        if x < 0 { throw Bad() }
        return x
    }

    public func classify(_ x: Int, _ xs: [Int], _ c: Bool) throws -> Int {
        switch x {
        case let y where try weight(y) > 100:
            var n = 0
            for v in xs where (c ? v > 1 : v < 5) {
                n += 1
            }
            return n
        default:
            return -1
        }
    }

    public func skip(_ n: Int, _ log: inout [String]) throws -> Bool {
        var i = 0
        repeat {
            i += 1
            if i % 2 == 0 { continue }
        } while i < n
        let v = try weight(i)
        log.append("after \\(v)")
        return v > 3
    }
    """

    // An `else if`'s condition runs only when the conditions before it don't hold, not each time the code before the
    // `if` does: below a count worked out again, it doesn't take that code's verdict. In a builder, after an `if` that
    // was never true, `n < -100` never ran in `nested(sink, false, 3)` and `nested(sink, false, 7)`, and `i < -5` never
    // ran in `ladder(2, &log)`, after a `repeat` left by `break`.
    func test_anElseIfThatNeverRan_belowACountWorkedOutAgain_isLeftOut() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode(Self.elseIfThatNeverRanCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [4, 67, 15, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 15, 2, 0], [8, 8, 8, 13, 0],
                    [8, 14, 14, 6, 2], [9, 12, 9, 18, 2], [9, 19, 11, 10, 2], [11, 19, 11, 27, 0], [11, 28, 13, 10, 0],
                    [13, 10, 14, 6, 2], [14, 6, 15, 2, 4],
                ],
                [[17, 36, 20, 2, 1], [18, 8, 18, 13, 1], [18, 14, 18, 29, 0], [18, 29, 19, 13, 1]],
                [
                    [22, 67, 34, 2, 1], [24, 12, 27, 6, 2], [26, 12, 26, 18, 2], [26, 19, 26, 28, 1],
                    [26, 28, 27, 6, 1], [27, 6, 33, 13, 0], [27, 13, 27, 18, 1], [28, 8, 28, 14, 0],
                    [28, 28, 33, 13, 0], [28, 34, 30, 6, 1], [30, 15, 30, 21, negative], [30, 22, 32, 6, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@26",
            "RelationalOperatorReplacement@26", "RelationalOperatorReplacement@27", "RelationalOperatorReplacement@27",
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@28",
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@8",
            "RelationalOperatorReplacement@9", "RelationalOperatorReplacement@9", "RemoveSideEffects@10",
            "RemoveSideEffects@29",
        ])
    }

    private static let elseIfThatNeverRanCode = """
    import Foundation

    @ListBuilder
    public func nested(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if a {
            sink.note("a")
        }
        if n > 0 {
            if n < 50 {
                sink.note("small")
            } else if n < -100 {
                sink.note("neg")
            }
        }
    }

    func check(_ x: Int) throws -> Int {
        if x < 0 { throw Bad() }
        return x
    }

    public func ladder(_ n: Int, _ log: inout [String]) throws -> Int {
        var i = 0
        repeat {
            i += 1
            if i == n { break }
        } while i < 5
        if i >= 0, try check(i) >= 0 {
            log.append("pos")
        } else if i < -5 {
            log.append("neg")
        }
        return i
    }
    """

    // Below an `else` the walk works out as never run, though llvm-cov reads some, its counts say nothing: `n < -5`
    // never ran. Below a region that reads 0, a builder's counts the walk can't work out say nothing even in code that
    // Swift counts directly and that ran, as a loop's body, since they're as stale there: `i > 0` ran, but only the
    // call that holds it counts as run, as main has it. And a call that threw in a closure's capture list leaves the
    // code after it unrun: `n > 3` never ran.
    func test_countsSayNothing_belowARegionThatReadsZero_evenInCodeThatRan() throws {
        let source = try sourceCode(Self.codeBelowARegionThatReadsZero)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 38, 6, 2, 2], [4, 8, 4, 13, 2], [4, 14, 4, 29, 2], [4, 29, 5, 13, 0]],
                [
                    [9, 73, 18, 2, 2], [10, 8, 10, 10, 2], [10, 11, 12, 6, 2], [12, 6, 18, 2, 4], [13, 8, 13, 13, 4],
                    [13, 14, 15, 6, 2], [15, 12, 17, 6, 2], [16, 40, 16, 73, 2], [16, 63, 16, 66, 0],
                    [16, 69, 16, 72, 2],
                ],
                [[16, 78, 16, 80, 0]],
                [
                    [21, 81, 28, 2, 1], [22, 8, 22, 9, 1], [22, 10, 24, 6, 0], [24, 6, 28, 2, 0], [25, 20, 27, 6, 2],
                    [26, 40, 26, 68, 2], [27, 6, 28, 2, 0],
                ],
                [[26, 73, 26, 75, 0]],
                [
                    [30, 66, 36, 2, 2], [31, 24, 31, 55, 2], [31, 46, 31, 55, 0], [31, 55, 35, 15, 0],
                    [31, 58, 31, 63, 0], [32, 8, 32, 13, 0], [32, 14, 34, 6, 0],
                ],
                [[31, 25, 31, 54, 0]],
                [[31, 58, 31, 63, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@31",
            "RelationalOperatorReplacement@31", "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4",
            "RemoveSideEffects@11", "RemoveSideEffects@14", "RemoveSideEffects@26", "SwapTernary@31",
        ])
    }

    private static let codeBelowARegionThatReadsZero = """
    import Foundation

    func mayFail(_ n: Int) throws -> Int {
        if n < 0 { throw Bad() }
        return n
    }

    @ListBuilder
    public func neverElseTry(_ sink: Sink, _ a: Bool, _ n: Int) -> [String] {
        if !a {
            sink.note("t")
        }
        if n > 0 {
            sink.note("pos")
        } else {
            sink.note((try? sink.check("x") + sink.check(n < -5 ? "q" : "r")) ?? "")
        }
    }

    @ListBuilder
    public func loopAfterNever(_ sink: Sink, _ a: Bool, _ items: [Int]) -> [String] {
        if a {
            sink.note("a")
        }
        for i in items {
            sink.note((try? sink.check("x") + sink.check(String(i > 0))) ?? "")
        }
    }

    public func ternaryCapture(_ n: Int, _ sink: Sink) throws -> Int {
        let k = n > -100 ? ({ [v = try mayFail(n)] in v }) : { 0 }
        if n > 3 {
            sink.note("big")
        }
        return k()
    }
    """
}
