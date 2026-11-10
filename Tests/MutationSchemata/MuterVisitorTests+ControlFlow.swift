@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MuterVisitorTests {
    // A `#if` inside the `#if` clause the build kept starts on a skipped directive too. The `return` in it still
    // leaves the function, so the last line never ran.
    func test_aNestedIfConfig_isWalkedInTheClauseTheBuildKept() throws {
        let source = try sourceCode("""
        import Foundation

        public func first(_ x: Int) -> Int {
            if x > 0 {
                #if os(macOS)
                #if DEBUG
                let y = x
                #endif
                return y
                #endif
            }
            return x == 0 ? 0 : -1
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [3, 36, 13, 2, 2], [4, 8, 4, 13, 2], [4, 14, 11, 6, 2], [5, 9, 5, 22, 0, 2], [6, 9, 6, 18, 0, 2],
                    [8, 9, 8, 15, 0, 2], [10, 9, 10, 15, 0, 2], [11, 6, 12, 27, 0], [12, 21, 12, 22, 0],
                    [12, 25, 12, 27, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings), ["RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4"])
    }

    // Swift doesn't count a `break` out of a `repeat` loop as reaching the code after it, which then reads 0, though
    // `count(1, &log)` ran it. The loop's condition never ran.
    func test_theCodeAfterARepeatLoopLeftByBreak_isKept() throws {
        let source = try sourceCode("""
        import Foundation

        public func count(_ n: Int, _ log: inout [String]) {
            var i = 0
            repeat {
                i += 1
                if i >= n { break }
                log.append("loop")
            } while i < 10
            log.append("after")
            if n > 3 { log.append("big") }
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [3, 52, 12, 2, 1], [5, 12, 9, 6, 1], [7, 12, 7, 18, 1], [7, 19, 7, 28, 1], [7, 28, 9, 6, 0],
                    [9, 6, 12, 2, 0], [9, 13, 9, 19, 0], [11, 8, 11, 13, 0], [11, 14, 11, 35, 0],
                ],
            ])
        )

        // The call after the loop, on line 10, ran; the loop's on line 8, after the `break`, and the `if`'s on line 11
        // never did.
        XCTAssertEqual(
            Set(mutants(in: mappings)),
            ["RelationalOperatorReplacement@11", "RelationalOperatorReplacement@7", "RemoveSideEffects@10"]
        )
    }

    // Swift counts the code after a call in a `for` loop's `where` as the count before the loop less the times the call
    // threw: 0 here, though the `where` ran for 0, which it left out, and then threw for -1. Neither the loop's body
    // nor the code after it ran.
    func test_theCodeAfterACallInAForLoopsWhere_isCountedAsTheCountBeforeTheLoop() throws {
        let source = try sourceCode("""
        import Foundation

        func weight(_ x: Int) throws -> Int {
            if x < 0 { throw Bad() }
            return x
        }

        public func firstBig(_ xs: [Int], _ log: inout [String]) throws {
            for x in xs where try weight(x) > 1 {
                log.append("in \\(x)")
            }
            log.append("after")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 37, 6, 2, 2], [4, 8, 4, 13, 2], [4, 14, 4, 29, 1], [4, 29, 5, 13, 1]],
                [[8, 65, 13, 2, 1], [9, 36, 13, 2, 0], [9, 41, 11, 6, 0], [11, 6, 13, 2, 0]],
            ])
        )

        XCTAssertEqual(
            Set(mutants(in: mappings)),
            ["RelationalOperatorReplacement@4", "RelationalOperatorReplacement@9"]
        )
    }

    // The right-hand side of an operator a project declares can be a closure, as `???`'s is, and `~=` compares rather
    // than assigns. The innermost ternary on each line never ran. A ternary whose second branch has more than one term
    // isn't swapped.
    func test_whatFollowsAnOperatorThatMayTakeAClosure_isCountedOnItsOwn() throws {
        let source = try sourceCode("""
        import Foundation

        infix operator ??? : NilCoalescingPrecedence

        func ??? (lhs: Int?, rhs: @autoclosure () -> Int) -> Int {
            lhs ?? rhs()
        }

        public func fallback(_ o: Int?, _ c: Bool, _ n: Int) -> Int {
            o ??? n + (c ? 1 : (n > 5 ? 2 : 3))
        }

        public func inRange(_ a: Bool, _ c: Bool, _ n: Int) -> Bool {
            a && 1...5 ~= (c ? 1 : (n > 3 ? 2 : 9))
        }

        public func either(_ c: Bool, _ n: Int) -> Bool {
            c ? false : 1...5 ~= (n > 3 ? 2 : (n < 0 ? 9 : 8))
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[5, 58, 7, 2, 2]],
                [[6, 12, 6, 17, 1]],
                [[9, 61, 11, 2, 2]],
                [
                    [10, 11, 10, 40, 1], [10, 20, 10, 21, 1], [10, 24, 10, 39, 0], [10, 33, 10, 34, 0],
                    [10, 37, 10, 38, 0],
                ],
                [[13, 61, 15, 2, 2]],
                [
                    [14, 10, 14, 44, 1], [14, 24, 14, 25, 1], [14, 28, 14, 43, 0], [14, 37, 14, 38, 0],
                    [14, 41, 14, 42, 0],
                ],
                [
                    [17, 49, 19, 2, 2], [18, 9, 18, 14, 1], [18, 17, 18, 55, 1], [18, 35, 18, 36, 1],
                    [18, 39, 18, 54, 0], [18, 48, 18, 49, 0], [18, 52, 18, 53, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "ChangeLogicalConnector@14", "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@18",
            "SwapTernary@10", "SwapTernary@14", "SwapTernary@18", "SwapTernary@18",
        ])
    }

    // An operator that binds more loosely than a ternary ends its second branch, and can take the ternary after it as
    // a closure. `x < -5` ran in `lowRan(true, 1)`, and never in `lowNever(true, 9)`, and `lazyPick(4, false, 9)`
    // never ran its ternaries. A swap changes the whole sequence it's in, which ran.
    func test_anOperatorThatBindsMoreLooselyThanATernary_endsItsSecondBranch() throws {
        let source = try sourceCode(Self.looseOperatorAfterTernaryCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[11, 38, 13, 2, 3]],
                [[15, 58, 17, 2, 1]],
                [[16, 12, 16, 17, 0]],
                [
                    [19, 48, 21, 2, 2], [20, 9, 20, 10, 1], [20, 13, 20, 14, 1], [20, 28, 20, 30, 1],
                    [20, 33, 20, 51, 1], [20, 43, 20, 45, 0], [20, 48, 20, 50, 1],
                ],
                [
                    [23, 50, 25, 2, 1], [24, 9, 24, 10, 1], [24, 13, 24, 14, 0], [24, 28, 24, 30, 1],
                    [24, 33, 24, 51, 0], [24, 43, 24, 45, 0], [24, 48, 24, 50, 0],
                ],
                [[27, 61, 29, 2, 1]],
                [
                    [28, 11, 28, 34, 0], [28, 15, 28, 16, 0], [28, 19, 28, 34, 0], [28, 28, 28, 29, 0],
                    [28, 32, 28, 33, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@20",
            "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@24", "RelationalOperatorReplacement@24",
            "SwapTernary@20", "SwapTernary@20", "SwapTernary@20", "SwapTernary@24", "SwapTernary@24", "SwapTernary@28",
        ])
    }

    private static let looseOperatorAfterTernaryCode = """
    import Foundation

    precedencegroup LowestPrecedence {
        lowerThan: TernaryPrecedence
    }

    infix operator <<~ : LowestPrecedence

    infix operator ?<< : LowestPrecedence

    func <<~ (lhs: Int, rhs: Int) -> Int {
        lhs + rhs
    }

    func ?<< (lhs: Int?, rhs: @autoclosure () -> Int) -> Int {
        lhs ?? rhs()
    }

    public func lowRan(_ a: Bool, _ x: Int) -> Int {
        a ? 1 : 2 <<~ (x > 5 ? 10 : (x < -5 ? 20 : 30))
    }

    public func lowNever(_ a: Bool, _ x: Int) -> Int {
        a ? 1 : 2 <<~ (x > 5 ? 10 : (x < -5 ? 20 : 30))
    }

    public func lazyPick(_ o: Int?, _ c: Bool, _ n: Int) -> Int {
        o ?<< c ? n : (n > 5 ? 1 : 2)
    }
    """

    // A `repeat` loop's condition runs each time its body reaches its end or a `continue`, but Swift doesn't take the
    // times the body threw from its count: `k < (n > 5 ? 3 : 4)` never ran, `k < n + 10` ran 3 times, `k < n` twice,
    // and, where the walk can't work it out, `k < n` in `caseThrew` never ran. The code after a call in the condition
    // that may throw is also the code after the loop, which runs only when the condition fails: `k > n` never ran.
    // The condition `>= 0` gets its swap alone, as `true` would keep the loop going.
    func test_aRepeatLoopsCondition_runsWhenItsBodyReachesItsEndOrAContinue() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode(Self.repeatLoopConditionCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [3, 66, 10, 2, 1], [5, 12, 8, 6, 1], [7, 38, 8, 6, 0], [8, 6, 9, 13, 0], [8, 13, 8, 32, 1],
                    [8, 26, 8, 27, 0], [8, 30, 8, 31, 1],
                ],
                [[12, 65, 19, 2, 1], [14, 12, 17, 6, 4], [16, 35, 17, 6, 3], [17, 6, 18, 13, 0], [17, 13, 17, 23, 4]],
                [
                    [21, 67, 31, 2, 1], [23, 12, 29, 6, 3], [25, 12, 25, 17, 3], [25, 18, 27, 10, 2],
                    [27, 10, 29, 6, 1], [28, 38, 29, 6, 0], [29, 6, 30, 13, negative], [29, 13, 29, 18, 3],
                ],
                [
                    [33, 61, 43, 2, 1], [35, 12, 41, 6, 1], [37, 16, 37, 17, 1], [38, 9, 39, 42, 1], [40, 10, 41, 6, 0],
                    [41, 6, 42, 13, 0], [41, 13, 41, 18, 1],
                ],
                [
                    [45, 66, 52, 2, 1], [47, 12, 49, 6, 4], [49, 6, 51, 13, 1], [49, 13, 49, 40, 4],
                    [49, 35, 49, 40, 3], [49, 40, 51, 13, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@17", "RelationalOperatorReplacement@17", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@29", "RelationalOperatorReplacement@29",
            "RelationalOperatorReplacement@49", "RemoveSideEffects@16", "RemoveSideEffects@28", "RemoveSideEffects@39",
            "RemoveSideEffects@7",
        ])
    }

    private static let repeatLoopConditionCode = """
    import Foundation

    public func everyPassThrew(_ sink: Sink, _ n: Int) throws -> Int {
        var k = 0
        repeat {
            k += 1
            _ = try sink.number(k - 1000)
        } while k < (n > 5 ? 3 : 4)
        return k
    }

    public func lastPassThrew(_ sink: Sink, _ n: Int) throws -> Int {
        var k = 0
        repeat {
            k += 1
            _ = try sink.number(3 - k)
        } while k < n + 10
        return k
    }

    public func passesContinued(_ sink: Sink, _ n: Int) throws -> Int {
        var k = 0
        repeat {
            k += 1
            if k < 3 {
                continue
            }
            _ = try sink.number(k - 1000)
        } while k < n
        return k
    }

    public func caseThrew(_ sink: Sink, _ n: Int) throws -> Int {
        var k = 0
        repeat {
            k += 1
            switch k {
            default:
                _ = try sink.number(k - 1000)
            }
        } while k < n
        return k
    }

    public func conditionThrew(_ sink: Sink, _ n: Int) throws -> Int {
        var k = 0
        repeat {
            k += 1
        } while try sink.number(3 - k) >= 0
        sink.note(String(k > n))
        return k
    }
    """
}
