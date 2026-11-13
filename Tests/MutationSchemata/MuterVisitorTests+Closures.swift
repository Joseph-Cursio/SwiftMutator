@testable import muterCore
import TestingExtensions

extension MuterVisitorTests {
    // A closure literal shares its region with the initializer that makes it, which ran each time the property was
    // set. The closure's own count is the times it was called. Only `doubler` was.
    func test_aClosureThatAPropertyHolds_countsTheTimesItWasCalled() throws {
        let source = try sourceCode("""
        import Foundation

        public struct Holder {
            public let handler: (Int) -> Int = { x in x > 10 ? 1 : 2 }
            public let doubler: (Int) -> Int = { x in x > 0 ? x * 2 : 0 }
            public init() {}
        }

        public final class LazyHolder {
            public lazy var check: (Int) -> Bool = { x in x < 3 }
            public init() {}
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[4, 40, 4, 63, 1]],
                [[4, 40, 4, 63, 0], [4, 56, 4, 57, 0], [4, 60, 4, 61, 0]],
                [[5, 40, 5, 66, 1]],
                [[5, 40, 5, 66, 1], [5, 55, 5, 60, 1], [5, 63, 5, 64, 0]],
                [[6, 19, 6, 21, 1]],
                [[10, 44, 10, 58, 1]],
                [[10, 44, 10, 58, 0]],
                [[11, 19, 11, 21, 1]],
            ])
        )

        XCTAssertEqual(Set(mutants(in: mappings)), ["RelationalOperatorReplacement@5", "SwapTernary@5"])
    }

    // A closure that's a type's property's whole value, or a parameter's default, is made with the type or the call,
    // not where it's written: that it ran doesn't mean the code around it did. `base > 3` and `n > 3` never ran.
    func test_aClosureThatsAPropertysValueOrAParametersDefault_doesNotMeanTheCodeAroundItRan() throws {
        let source = try sourceCode("""
        import Foundation

        public func scaled(_ flag: Bool, _ sink: Sink, _ n: Int) -> Int {
            if flag {
                return Helper().scale(n)
            }
            let base = sink.note("dead").count
            struct Helper {
                let scale: (Int) -> Int = { x in x > 2 ? x * 2 : x }
            }
            return base > 3 ? 1 : 2
        }

        public func defaulted(_ flag: Bool, _ n: Int) -> Int {
            if flag {
                return pick(n)
            }
            func pick(_ x: Int, _ f: (Int) -> Int = { y in y > 2 ? y * 2 : y }) -> Int {
                f(x)
            }
            return n > 3 ? 1 : 2
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [
                    [3, 65, 12, 2, 2], [4, 8, 4, 12, 2], [4, 13, 6, 6, 2], [6, 6, 11, 28, 0], [11, 23, 11, 24, 0],
                    [11, 27, 11, 28, 0],
                ],
                [[9, 35, 9, 61, 2]],
                [[9, 35, 9, 61, 2], [9, 50, 9, 55, 1], [9, 58, 9, 59, 1]],
                [
                    [14, 54, 22, 2, 2], [15, 8, 15, 12, 2], [15, 13, 17, 6, 2], [17, 6, 21, 25, 0], [21, 20, 21, 21, 0],
                    [21, 24, 21, 25, 0],
                ],
                [[18, 45, 18, 71, 2], [18, 60, 18, 65, 1], [18, 68, 18, 69, 1]],
                [[18, 80, 20, 6, 2]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@9",
            "RelationalOperatorReplacement@9", "SwapTernary@18", "SwapTernary@9",
        ])
    }

    // The code in a closure's capture list runs where the closure is made, not when it's called:
    // `makeGreeter(nil, sink)` made the closure, but never called it.
    func test_codeInAClosuresCaptureList_doesNotMeanItsBodyRan() throws {
        let source = try sourceCode("""
        import Foundation

        func fallbackName() -> String { "friend" }

        public func makeGreeter(_ name: String?, _ sink: Sink) -> (Int) -> String {
            let greet = { [label = name ?? fallbackName()] (times: Int) -> String in
                sink.note("greet")
                return times > 1 ? label + "s" : label
            }
            return greet
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 31, 3, 43, 1]],
                [[5, 75, 11, 2, 1]],
                [[6, 17, 9, 6, 0], [8, 28, 8, 39, 0], [8, 42, 8, 47, 0]],
                [[6, 36, 6, 50, 1]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings), [])
    }

    // A closure's capture list runs where the closure is made, and a call or an `if` or `switch` there starts a region
    // of the function that makes it, which can run past the closure's end. The closures `makeTry`, `makeIf` and
    // `makeSwitch` make were never called, but `n > 5` ran, and the code after the `try` in `tryCaptureElse` never
    // ran, since it threw each time.
    func test_aClosuresCaptureList_isCodeOfTheFunctionThatMakesTheClosure() throws {
        let source = try sourceCode(Self.captureListCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 38, 6, 2, 3], [4, 8, 4, 13, 3], [4, 14, 4, 29, 2], [4, 29, 5, 13, 1]],
                [[8, 68, 14, 2, 1], [9, 34, 13, 13, 1]],
                [[9, 13, 12, 6, 0], [11, 24, 11, 25, 0], [11, 28, 11, 29, 0]],
                [
                    [16, 66, 24, 2, 2], [17, 34, 23, 15, 0], [18, 8, 18, 13, 0], [18, 14, 20, 6, 0], [20, 12, 22, 6, 0],
                    [21, 29, 21, 35, 0], [21, 38, 21, 45, 0],
                ],
                [[17, 13, 17, 46, 0]],
                [[26, 60, 32, 2, 1], [27, 23, 27, 28, 1], [27, 29, 27, 34, 1], [27, 40, 27, 45, 0]],
                [[27, 13, 30, 6, 0], [29, 24, 29, 25, 0], [29, 28, 29, 29, 0]],
                [
                    [34, 64, 40, 2, 1], [35, 27, 35, 28, 1], [35, 31, 35, 41, 0], [35, 42, 35, 52, 1],
                    [35, 54, 39, 13, 1],
                ],
                [[35, 13, 38, 6, 0], [37, 24, 37, 25, 0], [37, 28, 37, 29, 0]],
            ])
        )

        XCTAssertEqual(
            mutants(in: mappings).sorted(),
            [
                "RelationalOperatorReplacement@27", "RelationalOperatorReplacement@27",
                "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4",
            ]
        )
    }

    private static let captureListCode = """
    import Foundation

    func mayFail(_ n: Int) throws -> Int {
        if n < 0 { throw Bad() }
        return n
    }

    public func makeTry(_ n: Int, _ sink: Sink) throws -> (Int) -> Int {
        let k = { [v = try mayFail(n)] (x: Int) -> Int in
            sink.note("k")
            return x > v ? 1 : 2
        }
        return k
    }

    public func tryCaptureElse(_ n: Int, _ sink: Sink) throws -> Int {
        let k = { [v = try mayFail(n)] in v * 2 }
        if n > 3 {
            sink.note("big")
        } else {
            sink.note(n < -10 ? "tiny" : "small")
        }
        return k()
    }

    public func makeIf(_ n: Int, _ sink: Sink) -> (Int) -> Int {
        let k = { [v = if n > 5 { n } else { 0 }] (x: Int) -> Int in
            sink.note("k")
            return x > v ? 1 : 2
        }
        return k
    }

    public func makeSwitch(_ n: Int, _ sink: Sink) -> (Int) -> Int {
        let k = { [v = switch n { case 0: 1; default: 2 }] (x: Int) -> Int in
            sink.note("k")
            return x > v ? 1 : 2
        }
        return k
    }
    """

    // A closure made in another's capture list, and the code in its own, are code of the function that makes the
    // outer closure, which was never called: `n > 0` ran, but `x > f()`, `x > 12` and `a() > x` never did.
    func test_aClosureInAClosuresCaptureList_doesNotMeanTheOuterClosuresBodyRan() throws {
        let source = try sourceCode("""
        import Foundation

        func mayFail(_ n: Int) throws -> Int {
            if n < 0 { throw Bad() }
            return n
        }

        public func nestedTernary(_ n: Int, _ sink: Sink) -> (Int) -> Int {
            let k = { [f = { [y = n > 0 ? 1 : 2] () -> Int in 5 }] (x: Int) -> Int in
                sink.note("k")
                return x > f() ? 1 : 2
            }
            return k
        }

        public func nestedTry(_ n: Int, _ sink: Sink) throws -> (Int) -> Bool {
            let k = { [a = { [b = try mayFail(n)] () -> Int in 1 }] (x: Int) -> Bool in
                sink.note(String(x > 12))
                return a() > x
            }
            sink.note(String(n > 40))
            return k
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 38, 6, 2, 1], [4, 8, 4, 13, 1], [4, 14, 4, 29, 0], [4, 29, 5, 13, 1]],
                [[8, 67, 14, 2, 1], [9, 35, 9, 36, 1], [9, 39, 9, 40, 0]],
                [[9, 13, 12, 6, 0], [11, 26, 11, 27, 0], [11, 30, 11, 31, 0]],
                [[9, 20, 9, 58, 0]],
                [[16, 71, 23, 2, 1], [17, 41, 22, 13, 1]],
                [[17, 13, 20, 6, 0]],
                [[17, 20, 17, 59, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@21", "RelationalOperatorReplacement@21", "RelationalOperatorReplacement@4",
            "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@9", "RelationalOperatorReplacement@9",
            "RemoveSideEffects@21", "SwapTernary@9",
        ])
    }

    // A call in a closure's capture list starts a region of the function that makes the closure, which holds the code
    // after the closure: `n > 3` never ran, after the call always threw, and `w > 91` ran once, after it threw once.
    func test_codeAfterAClosure_isInTheRegionThatStartsInItsCaptureList() throws {
        let source = try sourceCode("""
        import Foundation

        func mayFail(_ n: Int) throws -> Int {
            if n < 0 { throw Bad() }
            return n
        }

        public func afterCaptureThrew(_ n: Int, _ sink: Sink) throws -> Int {
            let k = { [v = try mayFail(n)] (x: Int) -> Int in x > v ? 1 : 2 }
            sink.note(String(n > 3))
            return k(n)
        }

        public func afterCaptureRan(_ n: Int, _ m: Int, _ sink: Sink) throws -> Int {
            let k = { [v = try mayFail(n)] in v > 0 ? 1 : 2 }
            let w = try mayFail(m)
            sink.note(w > 91 ? "a" : "b")
            return k() + w
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 38, 6, 2, 5], [4, 8, 4, 13, 5], [4, 14, 4, 29, 3], [4, 29, 5, 13, 2]],
                [[8, 69, 12, 2, 2], [9, 34, 11, 16, 0]],
                [[9, 13, 9, 70, 0], [9, 63, 9, 64, 0], [9, 67, 9, 68, 0]],
                [
                    [14, 77, 19, 2, 2], [15, 34, 18, 19, 1], [16, 27, 18, 19, 1], [17, 24, 17, 27, 0],
                    [17, 30, 17, 33, 1],
                ],
                [[15, 13, 15, 54, 1], [15, 47, 15, 48, 1], [15, 51, 15, 52, 0]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@15", "RelationalOperatorReplacement@15", "RelationalOperatorReplacement@17",
            "RelationalOperatorReplacement@17", "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@4",
            "RemoveSideEffects@17", "SwapTernary@15", "SwapTernary@17",
        ])
    }
}
