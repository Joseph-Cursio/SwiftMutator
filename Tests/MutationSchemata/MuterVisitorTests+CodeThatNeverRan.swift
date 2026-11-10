@testable import muterCore
import TestingExtensions

extension MuterVisitorTests {
    // The right-hand side of `&&` is a closure with a region of its own, and no node of its own: the sequence
    // `a && b > c` is flat. This is the region llvm-cov gave it when the tests only called `check(false, 1, 2)`.
    func test_aMutantInAnUnrunRegionSmallerThanAnyNodeAroundIt_isLeftOut() throws {
        let source = try sourceCode("""
        import Foundation

        public func check(_ a: Bool, _ b: Int, _ c: Int) -> Bool {
            a && b > c
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [.make(lineStart: 4, columnStart: 10, lineEnd: 4, columnEnd: 15)]
        )

        // `&&` runs whenever the function does, and `>` only when `a` is true.
        XCTAssertEqual(mutants(in: mappings), ["ChangeLogicalConnector@4"])
    }

    // RemoveSideEffects adds its mutants as it reaches the function, before any node in the body has been checked.
    func test_removeSideEffects_inAFunctionNoTestCalled_isLeftOut() throws {
        let source = try sourceCode("""
        import Foundation

        public func neverCalled(_ log: inout [String]) {
            log.append("one")
            log.append("two")
        }

        public func called(_ log: inout [String]) {
            log.append("three")
            log.append("four")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            // The first function's body, as llvm-cov gives a function no test called.
            regionsWithoutCoverage: [.make(lineStart: 3, columnStart: 48, lineEnd: 6, columnEnd: 2)]
        )

        XCTAssertEqual(mutants(in: mappings), ["RemoveSideEffects@9", "RemoveSideEffects@10"])
    }

    // RemoveSideEffects replaces the body's whole statement list to remove one statement, so it's the statement that
    // must have run. This is llvm-cov's region for the code after an `if` whose body returned in every test.
    func test_removeSideEffects_checksTheStatementItRemoves_notTheWholeList() throws {
        let source = try sourceCode("""
        import Foundation

        public func record(_ log: inout [String], _ done: Bool) {
            log.append("one")
            if done { return }
            log.append("two")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [.make(lineStart: 5, columnStart: 23, lineEnd: 7, columnEnd: 2)]
        )

        XCTAssertEqual(mutants(in: mappings), ["RemoveSideEffects@4"])
    }

    // A swap changes what the branch that ran gives, so a ternary with a branch that never ran is still tested.
    func test_aTernaryWithOneBranchThatNeverRan_isKept() throws {
        let source = try sourceCode("""
        import Foundation

        public func pick(_ c: Bool) -> Int {
            c ? 1 : 2
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            // `2`, as llvm-cov gives it when the tests only call `pick(true)`.
            regionsWithoutCoverage: [.make(lineStart: 4, columnStart: 13, lineEnd: 4, columnEnd: 14)]
        )

        XCTAssertEqual(mutants(in: mappings), ["SwapTernary@4"])
    }

    // A statement's trailing comment isn't part of it, so a region that ends at its last character still holds it.
    func test_aNodesTrailingTrivia_doesNotTakeItOutOfARegionThatHoldsIt() throws {
        let source = try sourceCode("""
        import Foundation

        public func record(_ log: inout [String]) {
            log.append("one") // the first
            log.append("two")
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [.make(lineStart: 4, columnStart: 5, lineEnd: 4, columnEnd: 22)]
        )

        XCTAssertEqual(mutants(in: mappings), ["RemoveSideEffects@5"])
    }

    // A `muter:disable` tag in code that never ran still turns mutants off, and a `muter:enable` tag in code that never
    // ran on again: `isLeap`, `later` and `last` ran, after them.
    func test_disableAndEnableTags_inCodeThatNeverRan_stillTurnMutantsOffAndOn() throws {
        let source = try sourceCode(Self.taggedCodeThatNeverRan)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[3, 45, 10, 2, 1], [4, 25, 4, 42, 1], [4, 42, 9, 40, 0]],
                [[12, 41, 14, 2, 4]],
                [[13, 22, 13, 58, 3]],
                [[13, 42, 13, 57, 2]],
                [[16, 54, 25, 2, 1], [17, 8, 17, 12, 1], [17, 13, 17, 25, 1], [17, 25, 24, 13, 0]],
                [[18, 19, 21, 6, 0]],
                [[27, 50, 30, 2, 2], [29, 21, 29, 22, 1], [29, 25, 29, 26, 1]],
                [
                    [32, 40, 38, 2, 1], [34, 23, 34, 24, 1], [34, 27, 34, 28, 0], [35, 8, 35, 12, 1],
                    [35, 13, 35, 28, 1], [35, 28, 37, 20, 0],
                ],
                [[40, 36, 42, 2, 2]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "ChangeLogicalConnector@13", "ChangeLogicalConnector@13", "RelationalOperatorReplacement@13",
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@13",
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@29",
            "RelationalOperatorReplacement@29", "RelationalOperatorReplacement@41", "RelationalOperatorReplacement@41",
            "RemoveSideEffects@28", "SwapTernary@29",
        ])
    }

    private static let taggedCodeThatNeverRan = """
    import Foundation

    public func format(_ date: Date?) -> String {
        guard let date else { return "none" }
        // muter:disable
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        // muter:enable
        return formatter.string(from: date)
    }

    public func isLeap(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    public func early(_ flag: Bool, _ sink: Sink) -> Int {
        if flag { return 1 }
        func helper() {
            // muter:disable
            sink.note("helper")
        }
        // muter:enable
        helper()
        return 2
    }

    public func later(_ sink: Sink, _ x: Int) -> Int {
        sink.note("later")
        return x >= 3 ? 1 : 0
    }

    public func taken(_ flag: Bool) -> Int {
        // muter:disable
        let base = flag ? 1 : 2
        if flag { return base }
        // muter:enable
        return base + 1
    }

    public func last(_ x: Int) -> Bool {
        x > 3
    }
    """

    // A lock made in code that never ran, or by a type that was never made, has no calls that ran, so removing
    // `lock.bump()`, a call on another `lock`, is a mutant. A local type's property can be made though the code that
    // declares the type never ran, so removing a call on `gate` isn't.
    func test_removeSideEffects_leavesCallsOnLocksMadeInCodeThatRan_only() throws {
        let source = try sourceCode(Self.callsOnLocksCode)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            coverage: .llvmCov([
                [[4, 20, 4, 21, 1]],
                [[5, 19, 5, 21, 1]],
                [[6, 24, 6, 34, 2]],
                [[9, 44, 14, 2, 1], [10, 8, 10, 12, 1], [10, 13, 10, 25, 1], [10, 25, 13, 13, 0]],
                [[16, 45, 24, 2, 1], [17, 8, 17, 12, 1], [17, 13, 17, 25, 1], [17, 25, 23, 13, 0]],
                [[19, 20, 19, 37, 0]],
                [[20, 20, 20, 50, 0]],
                [[26, 43, 29, 2, 2]],
                [[31, 40, 44, 2, 1], [32, 8, 32, 12, 1], [32, 13, 34, 6, 1], [34, 6, 43, 13, 0]],
                [[36, 20, 36, 47, 1]],
                [[37, 27, 41, 10, 1]],
            ])
        )

        XCTAssertEqual(mutants(in: mappings), ["RemoveSideEffects@27"])
    }

    private static let callsOnLocksCode = """
    import Foundation

    public final class Counter {
        public var n = 0
        public init() {}
        public func bump() { n += 1 }
    }

    public func waitLater(_ flag: Bool) -> Int {
        if flag { return 1 }
        let lock = DispatchSemaphore(value: 0)
        lock.signal()
        return 2
    }

    public func guardLater(_ flag: Bool) -> Int {
        if flag { return 1 }
        final class Guarded {
            let lock = NSRecursiveLock()
            func run() { lock.lock(); lock.unlock() }
        }
        Guarded().run()
        return 2
    }

    public func count(_ lock: Counter) -> Int {
        lock.bump()
        return lock.n
    }

    public func boxed(_ flag: Bool) -> Int {
        if flag {
            return Box().get()
        }
        struct Box {
            let gate = DispatchSemaphore(value: 1)
            func get() -> Int {
                gate.wait()
                gate.signal()
                return 1
            }
        }
        return 0
    }
    """
}
