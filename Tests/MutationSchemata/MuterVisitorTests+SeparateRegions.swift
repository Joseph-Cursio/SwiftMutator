@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MuterVisitorTests {
    // Code that ran in a local function, or a local type's members, says nothing about the code that declares them,
    // which can call them first: here before an early `return`, which both tests take.
    func test_codeThatRanInALocalFunctionOrType_doesNotMeanTheCodeAroundItRan() throws {
        let source = try sourceCode(Self.localFunctionOrTypeCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [3, 69, 15, 2, 1], [4, 8, 4, 12, 1], [4, 13, 6, 6, 1], [6, 6, 14, 34, 0], [14, 29, 14, 30, 0],
                    [14, 33, 14, 34, 0],
                ],
                [[8, 34, 13, 6, 1], [9, 12, 9, 17, 1], [9, 18, 11, 10, 1], [11, 10, 12, 17, 0]],
                [
                    [17, 55, 31, 2, 1], [18, 8, 18, 12, 1], [18, 13, 20, 6, 1], [20, 6, 30, 25, 0], [30, 20, 30, 21, 0],
                    [30, 24, 30, 25, 0],
                ],
                [[22, 20, 22, 25, 1]],
                [[23, 29, 28, 10, 1], [24, 16, 24, 24, 1], [24, 25, 26, 14, 1], [26, 14, 27, 21, 0]],
            ])
        )

        XCTAssertEqual(
            Set(mutants(in: mappings)),
            ["RelationalOperatorReplacement@9", "RelationalOperatorReplacement@24"]
        )
    }

    private static let localFunctionOrTypeCode = """
    import Foundation

    public func localBefore(_ flag: Bool, _ log: inout [String]) -> Int {
        if flag {
            return helper(3)
        }
        log.append("dead")
        func helper(_ x: Int) -> Int {
            if x > 2 {
                return x * 2
            }
            return x
        }
        return log.count == 4 ? 1 : 2
    }

    public func typeBefore(_ flag: Bool, _ n: Int) -> Int {
        if flag {
            return Inner().value()
        }
        struct Inner {
            var seed = 2 + 1
            func value() -> Int {
                if seed > 1 {
                    return seed
                }
                return 0
            }
        }
        return n > 3 ? 1 : 2
    }
    """

    // A closure literal that's the whole body of a function that makes it, an implicit closure or a property's
    // initializer, is made as often as that function runs, which runs its capture list, and the closure's own record
    // is the one with regions in its body: `n > 7` ran and `v > 1` never did. Its capture list isn't code of the
    // function around it: in `laterArgument`, `n < -5` ran twice, and nothing in `neverEvaluated` ran. A local
    // type's property makes it with each instance, and a struct's memberwise init can leave that at 0: nothing in
    // `neverMade` ran, and everything in `madeAndCalled` did.
    func test_aClosureMadeByAFunctionOfItsOwn_isJudgedByThatFunctionsCounts() throws {
        let source = try sourceCode(Self.closureMadeByAFunctionCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[7, 91, 10, 2, 3], [8, 19, 9, 16, 1]],
                [[12, 72, 17, 2, 1], [13, 20, 15, 6, 1], [15, 6, 16, 20, 0]],
                [[19, 86, 22, 2, 1], [21, 19, 21, 22, 0], [21, 25, 21, 30, 1]],
                [[20, 18, 20, 50, 1], [20, 33, 20, 34, 0], [20, 37, 20, 38, 1]],
                [[20, 18, 20, 50, 0]],
                [
                    [24, 66, 26, 2, 3], [25, 66, 25, 70, 1], [25, 73, 25, 109, 2], [25, 92, 25, 95, 0],
                    [25, 98, 25, 101, 2], [25, 110, 26, 2, 1],
                ],
                [[25, 19, 25, 56, 3], [25, 44, 25, 56, 1]],
                [[25, 19, 25, 56, 1]],
                [[28, 46, 30, 2, 1]],
                [
                    [29, 11, 29, 57, 0], [29, 26, 29, 27, 0], [29, 30, 29, 45, 0], [29, 39, 29, 40, 0],
                    [29, 43, 29, 44, 0],
                ],
                [[29, 11, 29, 57, 0]],
                [[32, 54, 41, 2, 1], [37, 8, 37, 12, 1], [37, 13, 39, 6, 0]],
                [[34, 36, 34, 87, 0]],
                [[34, 36, 34, 87, 0]],
                [[34, 80, 34, 85, 0]],
                [[35, 16, 35, 18, 0]],
                [[43, 45, 49, 2, 1]],
                [[45, 36, 45, 94, 0]],
                [[45, 36, 45, 94, 1], [45, 79, 45, 84, 1], [45, 87, 45, 92, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@45", "RelationalOperatorReplacement@45",
            "RelationalOperatorReplacement@45", "RelationalOperatorReplacement@45", "RemoveSideEffects@8",
            "SwapTernary@20", "SwapTernary@21", "SwapTernary@25", "SwapTernary@25", "SwapTernary@45",
        ])
    }

    private static let closureMadeByAFunctionCode = """
    import Foundation

    public enum Knobs {
        public static var limit = 5
    }

    func evaluated(_ make: @autoclosure () throws -> () -> Bool, _ flag: Bool) throws -> Bool {
        _ = try make()()
        return flag
    }

    func never(_ make: @autoclosure () -> () -> Bool, _ use: Bool) -> Bool {
        guard use else {
            return false
        }
        return make()()
    }

    public func coalescedNeverCalled(_ n: Int, _ f: (() -> Bool)?, _ call: Bool) -> Bool {
        let k = f ?? { [v = n > 7 ? 1 : 2] in v > 1 }
        return call ? k() : false
    }

    public func laterArgument(_ sink: Sink, _ n: Int) throws -> Bool {
        try evaluated({ [v = try sink.number(n)] in v > 1 }, n > 0 ? true : sink.note(n < -5 ? "i" : "j") == "j")
    }

    public func neverEvaluated(_ n: Int) -> Bool {
        never({ [v = n > 8 ? 1 : (n < 5 ? 2 : 3)] in v > 1 }, false)
    }

    public func neverMade(_ n: Int, _ make: Bool) -> Int {
        final class Local {
            let check: (Int) -> Bool = { [strict = Knobs.limit > 3] x in strict || x > 0 }
            init() {}
        }
        if make {
            _ = Local().check(n)
        }
        return n
    }

    public func madeAndCalled(_ n: Int) -> Bool {
        struct Rule {
            let check: (Int) -> Bool = { [strict = Knobs.limit > 4] x in strict ? x > 0 : false }
            var name: String
        }
        return Rule(name: "r").check(n)
    }
    """

    // A `repeat` loop's condition runs after each pass, but the code after the loop only once the condition fails:
    // `k < (n > 0 ? 100 : 50)` ran, but `k > 5` never did. A `case`'s `where` runs for each value it's tried on, but
    // its body only when it holds: `x > 0 && isBig(x)` ran, but `x > 500` never did.
    func test_codeThatRunsApartFromTheRegionAroundIt_doesNotMeanTheRestOfItRan() throws {
        let source = try sourceCode("""
        import Foundation

        func isBig(_ x: Int) -> Bool { x > 100 }

        public func leftByThrow(_ sink: Sink, _ n: Int) throws -> Int {
            var k = 0
            repeat {
                k += 1
                _ = try sink.number(k >= n ? -1000 : k)
            } while k < (n > 0 ? 100 : 50)
            return k > 5 ? 1 : 2
        }

        public func whereRan(_ n: Int) -> String {
            switch n {
            case let x where x > 0 && isBig(x):
                return x > 500 ? "huge" : "big"
            default:
                return "other"
            }
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 30, 3, 41, 1]],
                [
                    [5, 63, 12, 2, 1], [7, 12, 10, 6, 2], [9, 38, 9, 43, 1], [9, 46, 9, 47, 1], [9, 48, 10, 6, 1],
                    [10, 6, 11, 25, 0], [10, 13, 10, 35, 2], [10, 26, 10, 29, 1], [10, 32, 10, 34, 1],
                    [11, 20, 11, 21, 0], [11, 24, 11, 25, 0],
                ],
                [
                    [14, 42, 21, 2, 1], [15, 12, 15, 13, 1], [16, 5, 17, 40, 0], [17, 26, 17, 32, 0],
                    [17, 35, 17, 40, 0], [18, 5, 19, 23, 1],
                ],
                [[16, 31, 16, 39, 1]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "ChangeLogicalConnector@16", "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@10",
            "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@16",
            "RelationalOperatorReplacement@16", "RelationalOperatorReplacement@3", "RelationalOperatorReplacement@3",
            "RelationalOperatorReplacement@9", "RelationalOperatorReplacement@9", "RemoveSideEffects@9",
            "SwapTernary@10", "SwapTernary@9",
        ])
    }

    // A closure that's the whole of a ternary's branch, of `??`'s right-hand side, or of an implicit closure, is made
    // only when that runs, as is its capture list: `n > 6`, `n > 7`, `n > 8` and `n > 9` never ran, and `n > 10` did.
    // The code in its body runs only when it's called: `n > 11` ran, and `n > 12` never did.
    func test_aClosureThatsAWholeBranch_hasItsCaptureListJudgedByTheBranch() throws {
        let source = try sourceCode(Self.closureThatsAWholeBranchCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 72, 8, 2, 1], [4, 20, 6, 6, 1], [6, 6, 7, 20, 0]],
                [[10, 53, 13, 2, 1], [11, 29, 11, 49, 0], [11, 52, 11, 61, 1]],
                [[11, 29, 11, 49, 0]],
                [[11, 52, 11, 61, 1]],
                [[15, 53, 18, 2, 1], [16, 29, 16, 38, 1], [16, 41, 16, 61, 0]],
                [[16, 29, 16, 38, 1]],
                [[16, 41, 16, 61, 0]],
                [[20, 61, 23, 2, 1]],
                [[21, 18, 21, 38, 0]],
                [[21, 18, 21, 38, 0]],
                [[25, 42, 25, 80, 1]],
                [[25, 50, 25, 70, 0]],
                [[25, 50, 25, 70, 0]],
                [[27, 48, 30, 2, 2], [28, 29, 28, 50, 2], [28, 53, 28, 62, 0]],
                [[28, 29, 28, 50, 2]],
                [[28, 53, 28, 62, 0]],
                [[32, 62, 34, 2, 1], [33, 9, 33, 40, 1], [33, 43, 33, 52, 0]],
                [[33, 9, 33, 40, 0]],
                [[33, 32, 33, 38, 0]],
                [[33, 43, 33, 52, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@33",
            "RelationalOperatorReplacement@33", "SwapTernary@11", "SwapTernary@16", "SwapTernary@28", "SwapTernary@33",
        ])
    }

    private static let closureThatsAWholeBranchCode = """
    import Foundation

    func later(_ make: @autoclosure () -> () -> Bool, _ use: Bool) -> Bool {
        guard use else {
            return false
        }
        return make()()
    }

    public func thenBranch(_ n: Int, _ c: Bool) -> Bool {
        let k: () -> Bool = c ? { [v = n > 6] in v } : { false }
        return k()
    }

    public func elseBranch(_ n: Int, _ c: Bool) -> Bool {
        let k: () -> Bool = c ? { false } : { [v = n > 7] in v }
        return k()
    }

    public func coalesced(_ n: Int, _ f: (() -> Bool)?) -> Bool {
        let k = f ?? { [v = n > 8] in v }
        return k()
    }

    public func autoclosed(_ n: Int) -> Bool { later({ [v = n > 9] in v }, false) }

    public func taken(_ n: Int, _ c: Bool) -> Bool {
        let k: () -> Bool = c ? { [v = n > 10] in v } : { false }
        return k()
    }

    public func madeNotCalled(_ n: Int, _ c: Bool) -> () -> Bool {
        c ? { [v = n > 11] in v && n > 12 } : { false }
    }
    """
}
