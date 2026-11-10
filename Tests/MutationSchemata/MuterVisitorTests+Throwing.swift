@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension MuterVisitorTests {
    // What a `try` threw in a `where` or a ternary's branch makes the code after it run less. The tests call
    // `collect([1], &log)`, which throws, and `pick(true, 1)`, which throws, and `pick(false, 5)`, which doesn't:
    // line 12 never ran, and line 19 ran once.
    func test_theCodeAfterATry_countsTheTimesItDidNotThrow() throws {
        let source = try sourceCode("""
        import Foundation

        func validate(_ x: Int) throws -> Bool {
            if x > 0 { throw Bad() }
            return true
        }

        public func collect(_ xs: [Int], _ log: inout [String]) throws {
            for x in xs where try validate(x) {
                log.append("in \\(x)")
            }
            if xs.count > 100 {
                log.append("many")
            }
        }

        public func pick(_ c: Bool, _ n: Int) throws -> Bool {
            let v = c ? try validate(n) : false
            return n > 100 ? v : !v
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 40, 6, 2, 2], [4, 8, 4, 13, 2], [4, 14, 4, 29, 2], [4, 29, 5, 16, 0]],
                [
                    [8, 64, 15, 2, 1], [9, 38, 15, 2, 0], [9, 39, 11, 6, 0], [11, 6, 15, 2, 0], [12, 8, 12, 22, 0],
                    [12, 23, 14, 6, 0],
                ],
                [
                    [17, 54, 20, 2, 2], [18, 17, 18, 32, 1], [18, 32, 19, 28, 1], [18, 35, 18, 40, 1],
                    [19, 22, 19, 23, 0], [19, 26, 19, 28, 1],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@4", "SwapTernary@18", "RelationalOperatorReplacement@19", "SwapTernary@19",
        ])
    }

    // Swift counts the code after a throwing call in a `case`'s `where` as the case's count less the throws, though a
    // throw comes before the case is entered: 0 here, though `classify(150)` ran both comparisons.
    func test_aCaseWhoseWhereThrew_countsTheTimesTheCaseWasEntered() throws {
        let source = try sourceCode("""
        import Foundation

        func weight(_ x: Int) throws -> Int {
            if x < 0 { throw Bad() }
            return x
        }

        public func classify(_ x: Int) throws -> Bool {
            switch x {
            case let y where try weight(y) > 100:
                return y <= 200
            default:
                return false
            }
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 37, 6, 2, 2], [4, 8, 4, 13, 2], [4, 14, 4, 29, 1], [4, 29, 5, 13, 1]],
                [[8, 47, 15, 2, 2], [9, 12, 9, 13, 2], [10, 5, 11, 24, 1], [10, 35, 11, 24, 0], [12, 5, 13, 21, 0]],
            ])
        )

        XCTAssertEqual(
            Set(mutants(in: mappings)),
            ["RelationalOperatorReplacement@4", "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@11"]
        )
    }

    // A `try` covers every term after it, so what `mayFail(b)` threw comes off the count after the line: the tests call
    // `total(1, -1)` and `total(2, -1)`, which both throw, and nothing after line 9 ran.
    func test_aTryCoversTheTermsAfterIt() throws {
        let source = try sourceCode("""
        import Foundation

        func mayFail(_ x: Int) throws -> Int {
            if x < 0 { throw Bad() }
            return x
        }

        public func total(_ a: Int, _ b: Int) throws -> Int {
            let v = try mayFail(a) + mayFail(b)
            if v > 100 { return 1 }
            return v == 0 ? 2 : 3
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 38, 6, 2, 4], [4, 8, 4, 13, 4], [4, 14, 4, 29, 2], [4, 29, 5, 13, 2]],
                [
                    [8, 53, 12, 2, 2], [9, 27, 11, 26, 2], [9, 40, 11, 26, 0], [10, 8, 10, 15, 0], [10, 16, 10, 28, 0],
                    [10, 28, 11, 26, 0], [11, 21, 11, 22, 0], [11, 25, 11, 26, 0],
                ],
            ])
        )

        XCTAssertEqual(mutants(in: mappings), ["RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4"])
    }

    // The count before a ternary in an `if`'s second condition is unknown, so the count after a branch that may throw,
    // which runs past the ternary, is llvm-cov's: 1 here, from `pick(true, false, 5)`, not the branch's 0. A `try!`
    // may throw too, as Swift counts it: its branch never ran in `forced(false, 5)`, and the line after it did.
    func test_aTernaryBranchThatMayThrow_whenTheCountBeforeIsUnknown_leavesTheCountAfterIt() throws {
        let source = try sourceCode("""
        import Foundation

        func mayFail(_ x: Int) throws -> Int {
            if x < 0 { throw Bad() }
            return x
        }

        public func pick(_ a: Bool, _ c: Bool, _ n: Int) throws -> Int {
            if a, (c ? try mayFail(n) : 0) > 1 {
                return 1
            }
            return 0
        }

        public func forced(_ c: Bool, _ n: Int) -> Int {
            let v = c ? try! mayFail(n) : 0
            return v > 1 ? 1 : 0
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 38, 6, 2, 0], [4, 8, 4, 13, 0], [4, 14, 4, 29, 0], [4, 29, 5, 13, 0]],
                [
                    [8, 64, 13, 2, 1], [9, 8, 9, 9, 1], [9, 16, 9, 30, 0], [9, 30, 12, 13, 1], [9, 33, 9, 34, 1],
                    [9, 40, 11, 6, 0], [11, 6, 12, 13, 1],
                ],
                [
                    [15, 48, 18, 2, 1], [16, 17, 16, 32, 0], [16, 32, 17, 25, 1], [16, 35, 16, 36, 1],
                    [17, 20, 17, 21, 0], [17, 24, 17, 25, 1],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@9", "SwapTernary@9", "SwapTernary@16", "RelationalOperatorReplacement@17",
            "SwapTernary@17",
        ])
    }

    // A call that ends a case starts no region after it, which would be empty, but what it threw still comes off the
    // count after the `switch`: both calls threw, and nothing after the `switch` ran.
    func test_aCaseThatEndsInACallThatThrew_leavesTheCountAfterTheSwitch() throws {
        let source = try sourceCode("""
        import Foundation

        func check(_ x: Int) throws {
            if x < 0 { throw Bad() }
        }

        public func route(_ x: Int, _ log: inout [String]) throws -> Bool {
            switch x {
            case 0:
                try check(-1)
            default:
                try check(x)
            }
            log.append("after")
            return x > 5
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 29, 5, 2, 2], [4, 8, 4, 13, 2], [4, 14, 4, 29, 2], [4, 29, 5, 2, 0]],
                [[7, 67, 16, 2, 2], [8, 12, 8, 13, 2], [9, 5, 10, 22, 1], [11, 5, 12, 21, 1], [13, 6, 15, 17, 0]],
            ])
        )

        XCTAssertEqual(
            mutants(in: mappings), [
                "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4", "RemoveSideEffects@10",
                "RemoveSideEffects@12",
            ]
        )
    }

    // An `else if` is in a region Swift doesn't record, so what a call in its condition threw can't be read from the
    // regions around it. The tests call `ran` with 200 and 1, `never` with 200 and 50, and `decode` with 200 and -1,
    // which throws: the `else` ran in `ran` and never in `never`, and the code after the `if` in `decode` ran once.
    // Nothing in that code is counted directly, which would show it ran.
    func test_anElseIfWhoseConditionMayThrow_keepsLlvmCovsCounts() throws {
        let source = try sourceCode(Self.elseIfConditionThatMayThrowCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 37, 6, 2, 3], [4, 8, 4, 13, 3], [4, 14, 4, 29, 1], [4, 29, 5, 18, 2]],
                [
                    [8, 64, 17, 2, 2], [9, 8, 9, 15, 2], [9, 16, 11, 6, 1], [11, 15, 11, 27, 1], [11, 27, 16, 6, 1],
                    [11, 28, 13, 6, 0], [13, 12, 16, 6, 1], [15, 25, 15, 26, 1], [15, 29, 15, 30, 0],
                ],
                [
                    [19, 66, 28, 2, 2], [20, 8, 20, 15, 2], [20, 16, 22, 6, 1], [22, 15, 22, 27, 1],
                    [22, 27, 27, 6, 1], [22, 28, 24, 6, 1], [24, 12, 27, 6, 0], [26, 25, 26, 26, 0],
                    [26, 29, 26, 30, 0],
                ],
                [
                    [30, 67, 39, 2, 2], [32, 8, 32, 15, 2], [32, 16, 34, 6, 1], [34, 15, 34, 27, 1],
                    [34, 27, 36, 6, 0], [34, 28, 36, 6, 0], [36, 6, 38, 13, 1],
                ],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), [
            "RelationalOperatorReplacement@15", "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@32",
            "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@5", "RelationalOperatorReplacement@9",
            "RemoveSideEffects@14", "RemoveSideEffects@37", "SwapTernary@15",
        ])
    }

    private static let elseIfConditionThatMayThrowCode = """
    import Foundation

    func isBig(_ x: Int) throws -> Bool {
        if x < 0 { throw Bad() }
        return x > 10
    }

    public func ran(_ x: Int, _ log: inout [String]) throws -> Int {
        if x > 100 {
            return 1
        } else if try isBig(x) {
            return 2
        } else {
            log.append("else")
            return x == 1 ? 3 : 4
        }
    }

    public func never(_ x: Int, _ log: inout [String]) throws -> Int {
        if x > 100 {
            return 1
        } else if try isBig(x) {
            return 2
        } else {
            log.append("else")
            return x == 1 ? 3 : 4
        }
    }

    public func decode(_ x: Int, _ log: inout [String]) throws -> Int {
        var r = 0
        if x > 100 {
            r = 1
        } else if try isBig(x) {
            r = 2
        }
        log.append("after")
        return r
    }
    """
}
