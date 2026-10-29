@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class MuterVisitorTests: MuterTestCase {
    private var samplePath: String!

    override func setUpWithError() throws {
        try super.setUpWithError()

        samplePath = try makeTemporaryDirectory() + "/sampleWithDisabledCode.swift"
    }

    func test_shouldIgnoreSkippedLines() throws {
        FileManager.default.createFile(
            atPath: samplePath,
            contents: sampleWithDisabledMutations.data(using: .utf8)
        )

        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))
        let mappings = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertEqual(mappings.count, 1)

        XCTAssertEqual(mappings.first?.mutationSchemata.count, 1)
    }

    func test_shouldIgnoreComplexDisablingRules() throws {
        FileManager.default.createFile(
            atPath: samplePath,
            contents: sampleWithComplexDisableRules.data(using: .utf8)
        )

        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))
        let mappings = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertEqual(mappings.count, 1)

        let ids = mappings.first?.mutationSchemata.map(\.mutationOperatorId)
        XCTAssertEqual(
            ids,
            [.removeSideEffects, .ror, .swapTernary]
        )
    }

    func test_shouldIgnoreTopLevelDisable() throws {
        FileManager.default.createFile(
            atPath: samplePath,
            contents: sampleWithTopLevelDisable.data(using: .utf8)
        )

        let sourceCode = try XCTUnwrap(PrepareSourceCode().prepareSourceCode(samplePath))
        let mappings = generateSchemataMappings(
            for: sourceCode.source,
            changes: sourceCode.changes
        )

        XCTAssertTrue(mappings.isEmpty)
    }

    func test_ignoreRegionsWithoutCoverage() throws {
        let source = try sourceCode("""
        import Foundation

        public func foo(_ a: Bool, _ b: Bool) -> Bool {
            if a && b {
                return a == b
            }

            return true
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [
                .make(
                    lineStart: 4,
                    columnStart: 15,
                    lineEnd: 6,
                    columnEnd: 6
                ),
            ]
        )

        // The region is the `if` body, so `a == b` inside it goes. The condition `a && b` sits on the
        // region's first line but before it starts, and runs whether or not the body does.
        let mutants = mappings
            .flatMap(\.mutationSchemata)
            .map { "\($0.mutationOperatorId.rawValue)@\($0.position.line)" }
        XCTAssertEqual(mutants, ["ChangeLogicalConnector@4"])
    }

    // Every node's coverage check asks for its start and end. A location converter made for each took a pass over the
    // whole file each time, so a long file with any uncovered region took over a minute in a debug build.
    func test_regionsWithoutCoverage_keepDiscoveryFastOnALongFile() throws {
        let functions = (0 ..< 300).map { index in
            "public func check\(index)(_ a: Int, _ b: Int) -> Bool {\n    return a == b && a > \(index)\n}\n"
        }
        let source = try sourceCode("import Foundation\n\n" + functions.joined(separator: "\n"))
        let started = Date()

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [.make(lineStart: 3, columnStart: 50, lineEnd: 5, columnEnd: 2)]
        )

        let seconds = Date().timeIntervalSince(started)
        XCTAssertTrue(seconds < 5, "\(seconds) s")
        // The region is the first function's body, so its three mutants go, and every other function keeps its three.
        XCTAssertEqual(mappings.flatMap(\.mutationSchemata).count, 299 * 3)
    }

    func test_keepCoveredCodeAfterARegionWithoutCoverage() throws {
        let source = try sourceCode("""
        import Foundation

        public func foo(_ a: Bool, _ b: Bool) -> Bool {
            if a {
                return false
            }

            return a == b
        }
        """)

        let mappings = generateSchemataMappings(
            for: .init(path: "/path/to/file", code: source),
            changes: .null,
            regionsWithoutCoverage: [
                // The `if` body: it ends on line 6, before `a == b` on line 8 starts.
                .make(
                    lineStart: 4,
                    columnStart: 10,
                    lineEnd: 6,
                    columnEnd: 6
                ),
            ]
        )

        let mutants = mappings
            .flatMap(\.mutationSchemata)
            .map { "\($0.mutationOperatorId.rawValue)@\($0.position.line)" }
        XCTAssertEqual(mutants, ["RelationalOperatorReplacement@8"])
    }

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
            "RelationalOperatorReplacement@9", "SwapTernary@9",
            "RelationalOperatorReplacement@13", "SwapTernary@13", "RemoveSideEffects@13",
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

        XCTAssertEqual(mutants(in: mappings), ["RelationalOperatorReplacement@11", "RemoveSideEffects@14"])
    }

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

        XCTAssertEqual(mutants(in: mappings), ["RelationalOperatorReplacement@4"])
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

        // RemoveSideEffects leaves a body with a loop in it to the loop's own body.
        XCTAssertEqual(
            Set(mutants(in: mappings)),
            ["RelationalOperatorReplacement@7", "RelationalOperatorReplacement@11"]
        )
    }

    // A builder's cases in a `#if`, each ending in an `if` that was never true, so llvm-cov counts the code after the
    // `switch` as never run, and a builder with a `try`, which never threw. The tests call `kinds` with 0, 1 and 9, and
    // `risky(sink, false, 3)` and `risky(sink, false, 1)`: every condition and every line after the `switch` and the
    // `try` ran.
    func test_inAResultBuilder_casesInAnIfConfig_andATry_areWalked() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@7", "RelationalOperatorReplacement@12", "RelationalOperatorReplacement@17",
            "RelationalOperatorReplacement@21", "SwapTernary@21", "RemoveSideEffects@21",
            "RelationalOperatorReplacement@30", "SwapTernary@30", "RemoveSideEffects@30",
        ])
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

        XCTAssertEqual(mutants(in: mappings), ["RelationalOperatorReplacement@4"])
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
            "ChangeLogicalConnector@14", "RelationalOperatorReplacement@18", "SwapTernary@10", "SwapTernary@14",
            "SwapTernary@18",
        ])
    }

    // An operator that binds more loosely than a ternary ends its second branch, and can take the ternary after it as
    // a closure. `x < -5` ran in `lowRan(true, 1)`, and never in `lowNever(true, 9)`, and `lazyPick(4, false, 9)`
    // never ran its ternaries. A swap changes the whole sequence it's in, which ran.
    func test_anOperatorThatBindsMoreLooselyThanATernary_endsItsSecondBranch() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@24",
            "SwapTernary@20", "SwapTernary@20", "SwapTernary@20", "SwapTernary@24", "SwapTernary@24", "SwapTernary@28",
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

        XCTAssertEqual(mutants(in: mappings), ["RelationalOperatorReplacement@4"])
    }

    // An `else if` is in a region Swift doesn't record, so what a call in its condition threw can't be read from the
    // regions around it. The tests call `ran` with 200 and 1, `never` with 200 and 50, and `decode` with 200 and -1,
    // which throws: the `else` ran in `ran` and never in `never`, and the code after the `if` in `decode` ran once.
    // Nothing in that code is counted directly, which would show it ran.
    func test_anElseIfWhoseConditionMayThrow_keepsLlvmCovsCounts() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@5", "RelationalOperatorReplacement@9",
            "RelationalOperatorReplacement@15", "SwapTernary@15", "RelationalOperatorReplacement@20",
            "RelationalOperatorReplacement@32", "RemoveSideEffects@37",
        ])
    }

    // In a builder, after an `if` that was never true: a `try!` call starts a region of its own too, a `switch`'s
    // subject throwing doesn't change the count after it, and the code in a `try` runs as often as the `try` when only
    // its last call can throw. The tests call `forced(sink, false)`, `kind(sink, 0)` and `argument(sink, false, 1)` and
    // `argument(sink, false, 0)`, each twice or once each.
    func test_inAResultBuilder_aTryBang_aSwitchOnATry_andATernaryInATry_areWalked() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@16", "RelationalOperatorReplacement@30", "RelationalOperatorReplacement@30",
            "RemoveSideEffects@22", "RemoveSideEffects@9", "SwapTernary@30", "SwapTernary@30",
        ])
    }

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

    // In a builder, the count after a `try` is the wrong count before it less the times it threw, which is negative
    // and loses whether it threw every time. `once` threw for 1 of 3 calls, and "big" ran after it; `each` threw for
    // 1 of 2, and the closure after it ran; `always` threw for both, and nothing after it ran. The `else` in `ladder`,
    // after a condition that may throw, never ran either.
    func test_inAResultBuilder_theCodeAfterATryThatAlwaysThrew_isLeftOut() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@5", "RemoveSideEffects@9", "RelationalOperatorReplacement@9",
            "SwapTernary@9", "RelationalOperatorReplacement@14", "RemoveSideEffects@27",
            "RelationalOperatorReplacement@35", "RelationalOperatorReplacement@37",
        ])
    }

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
            "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@8", "RelationalOperatorReplacement@9",
            "RemoveSideEffects@8", "RemoveSideEffects@9", "SwapTernary@8", "SwapTernary@9",
        ])
    }

    // A negative count Swift gets wrong is worked out again, but a negative count in it that the walk can't work out
    // only repeats it, and counts as run, as llvm-cov's own negatives do: `v < 5` in the `case` that
    // `classify(150, ...)` entered, and the line after the `try` once `skip(4, &log)` left its `repeat` by `continue`.
    func test_aNegativeCountBelowANegativeCountWorkedOutAgain_ran() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@10", "RelationalOperatorReplacement@12", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@26", "RelationalOperatorReplacement@29", "RelationalOperatorReplacement@4",
            "SwapTernary@12",
        ])
    }

    // Code that ran in a local function, or a local type's members, says nothing about the code that declares them,
    // which can call them first: here before an early `return`, which both tests take.
    func test_codeThatRanInALocalFunctionOrType_doesNotMeanTheCodeAroundItRan() throws {
        let source = try sourceCode("""
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
        """)

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

    // An `else if`'s condition runs only when the conditions before it don't hold, not each time the code before the
    // `if` does: below a count worked out again, it doesn't take that code's verdict. In a builder, after an `if` that
    // was never true, `n < -100` never ran in `nested(sink, false, 3)` and `nested(sink, false, 7)`, and `i < -5` never
    // ran in `ladder(2, &log)`, after a `repeat` left by `break`.
    func test_anElseIfThatNeverRan_belowACountWorkedOutAgain_isLeftOut() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@26", "RelationalOperatorReplacement@27",
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@8",
            "RelationalOperatorReplacement@9",
        ])
    }

    // A `muter:disable` tag in code that never ran still turns mutants off, and a `muter:enable` tag in code that never
    // ran on again: `isLeap`, `later` and `last` ran, after them.
    func test_disableAndEnableTags_inCodeThatNeverRan_stillTurnMutantsOffAndOn() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@29",
            "RelationalOperatorReplacement@41", "RemoveSideEffects@28", "SwapTernary@29",
        ])
    }

    // A lock made in code that never ran, or by a type that was never made, has no calls that ran, so removing
    // `lock.bump()`, a call on another `lock`, is a mutant. A local type's property can be made though the code that
    // declares the type never ran, so removing a call on `gate` isn't.
    func test_removeSideEffects_leavesCallsOnLocksMadeInCodeThatRan_only() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@18", "RelationalOperatorReplacement@9", "SwapTernary@18", "SwapTernary@9",
        ])
    }

    // Swift counts the code in an `if`'s second condition as the code before the `if`, less the times a call there
    // threw. In a builder, after an `if` that was never true, line 13 ran in `secondTry(sink, false, 1)` and
    // `(sink, false, 2)`, and in `secondTernary`, after one that was always true too, `n < -9` never ran.
    func test_inAResultBuilder_anIfsSecondCondition_isWalkedFromTheCountBeforeTheIf() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@24", "RelationalOperatorReplacement@8",
            "RemoveSideEffects@13", "RemoveSideEffects@29", "SwapTernary@13", "SwapTernary@26",
        ])
    }

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
            "RelationalOperatorReplacement@11", "RemoveSideEffects@13", "SwapTernary@13",
        ])
    }

    // In a builder, after an `if` that was always true, Swift's counts are as much too high as the walk lowers the
    // count after the `if`. One it can't work out below that, but higher, ran: after a `for` loop whose `where` may
    // throw, in a `try` with two calls, and after a call in an `if`'s condition. Swift counts the code after a `switch`
    // from its cases, and that in a loop's body from the body's own count. Each line here ran in the tests.
    func test_inAResultBuilder_aCountHigherThanItCanBeTooHigh_ran() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@14", "RelationalOperatorReplacement@22", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@33", "RelationalOperatorReplacement@33", "RelationalOperatorReplacement@41",
            "RelationalOperatorReplacement@54", "RelationalOperatorReplacement@54", "RemoveSideEffects@14",
            "RemoveSideEffects@23", "RemoveSideEffects@33", "RemoveSideEffects@54", "SwapTernary@33", "SwapTernary@33",
            "SwapTernary@54", "SwapTernary@54",
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

    // In a builder, once the walk has lost the count, llvm-cov's counts can be stale, too high or too low, and it
    // keeps them as main does: below a region that reads 0, such as the code after an `if` that was never true, they
    // say nothing. In `halfTrue`, line 14 ran. In `neverElse` and `caseIf`, `n < -5000` never ran.
    func test_inAResultBuilder_countsTheWalkCantWorkOut_areKeptAsMainKeepsThem() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@11", "RelationalOperatorReplacement@14", "RelationalOperatorReplacement@22",
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@44", "RelationalOperatorReplacement@8",
            "RemoveSideEffects@23", "RemoveSideEffects@44", "RemoveSideEffects@9", "SwapTernary@28", "SwapTernary@44",
        ])
    }

    // A closure's capture list runs where the closure is made, and a call or an `if` or `switch` there starts a region
    // of the function that makes it, which can run past the closure's end. The closures `makeTry`, `makeIf` and
    // `makeSwitch` make were never called, but `n > 5` ran, and the code after the `try` in `tryCaptureElse` never
    // ran, since it threw each time.
    func test_aClosuresCaptureList_isCodeOfTheFunctionThatMakesTheClosure() throws {
        let source = try sourceCode("""
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
        """)

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
            ["RelationalOperatorReplacement@27", "RelationalOperatorReplacement@4"]
        )
    }

    // Below an `else` the walk works out as never run, though llvm-cov reads some, its counts say nothing: `n < -5`
    // never ran. Below a region that reads 0, a builder's counts the walk can't work out say nothing even in code that
    // Swift counts directly and that ran, as a loop's body, since they're as stale there: `i > 0` ran, but only the
    // call that holds it counts as run, as main has it. And a call that threw in a closure's capture list leaves the
    // code after it unrun: `n > 3` never ran.
    func test_countsSayNothing_belowARegionThatReadsZero_evenInCodeThatRan() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@13", "RelationalOperatorReplacement@31", "RelationalOperatorReplacement@4",
            "RemoveSideEffects@26", "SwapTernary@31",
        ])
    }

    // A closure literal that's the whole body of a function that makes it, an implicit closure or a property's
    // initializer, is made as often as that function runs, which runs its capture list, and the closure's own record
    // is the one with regions in its body: `n > 7` ran and `v > 1` never did. Its capture list isn't code of the
    // function around it: in `laterArgument`, `n < -5` ran twice, and nothing in `neverEvaluated` ran. A local
    // type's property makes it with each instance, and a struct's memberwise init can leave that at 0: nothing in
    // `neverMade` ran, and everything in `madeAndCalled` did.
    func test_aClosureMadeByAFunctionOfItsOwn_isJudgedByThatFunctionsCounts() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@20", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25",
            "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@45",
            "RelationalOperatorReplacement@45", "RemoveSideEffects@8", "SwapTernary@20", "SwapTernary@21",
            "SwapTernary@25", "SwapTernary@25", "SwapTernary@45",
        ])
    }

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
            "RelationalOperatorReplacement@16", "RelationalOperatorReplacement@3", "RelationalOperatorReplacement@9",
            "RemoveSideEffects@9", "SwapTernary@10", "SwapTernary@9",
        ])
    }

    // Below a region that reads 0, as after a builder's `if` that was never true, a builder's counts the walk can't
    // work out say nothing, in code that Swift counts directly and that ran too, as an `if`'s then-block or a closure:
    // after an `if` that was always true, they're too high there as well. So `n < -5000` never ran, in a ternary after
    // an operator the project declared, and in an `else` after a `for` whose `where` may throw, nor did `n > 50`, in a
    // closure that's such a ternary's `else`. One made there and called ran, as did its capture list: `n > -50` ran.
    // An implicit closure's count is its own, and so is that of the closure that's its body: `??`'s right-hand side
    // made one, so `n > 60` ran.
    func test_belowARegionThatReadsZero_aBuildersCountsInCodeThatRan_sayNothing() throws {
        let source = try sourceCode("""
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
        """)

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

        XCTAssertEqual(mutants(in: mappings).sorted(), [
            "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@40", "RelationalOperatorReplacement@46",
            "RelationalOperatorReplacement@76", "RelationalOperatorReplacement@87", "RemoveSideEffects@31",
            "RemoveSideEffects@41", "RemoveSideEffects@87", "SwapTernary@15", "SwapTernary@30", "SwapTernary@63",
            "SwapTernary@76",
        ])
    }

    // A `repeat` loop's condition runs each time its body reaches its end or a `continue`, but Swift doesn't take the
    // times the body threw from its count: `k < (n > 5 ? 3 : 4)` never ran, `k < n + 10` ran 3 times, `k < n` twice,
    // and, where the walk can't work it out, `k < n` in `caseThrew` never ran. The code after a call in the condition
    // that may throw is also the code after the loop, which runs only when the condition fails: `k > n` never ran.
    func test_aRepeatLoopsCondition_runsWhenItsBodyReachesItsEndOrAContinue() throws {
        let negative = 9_223_372_036_854_775_807
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@17", "RelationalOperatorReplacement@25", "RelationalOperatorReplacement@29",
            "RelationalOperatorReplacement@49", "RemoveSideEffects@16", "RemoveSideEffects@28", "RemoveSideEffects@7",
        ])
    }

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
            "RelationalOperatorReplacement@21", "RelationalOperatorReplacement@4", "RelationalOperatorReplacement@9",
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
            "RelationalOperatorReplacement@15", "RelationalOperatorReplacement@17", "RelationalOperatorReplacement@4",
            "RemoveSideEffects@17", "SwapTernary@15", "SwapTernary@17",
        ])
    }

    // A closure that's the whole of a ternary's branch, of `??`'s right-hand side, or of an implicit closure, is made
    // only when that runs, as is its capture list: `n > 6`, `n > 7`, `n > 8` and `n > 9` never ran, and `n > 10` did.
    // The code in its body runs only when it's called: `n > 11` ran, and `n > 12` never did.
    func test_aClosureThatsAWholeBranch_hasItsCaptureListJudgedByTheBranch() throws {
        let source = try sourceCode("""
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
        """)

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
            "RelationalOperatorReplacement@28", "RelationalOperatorReplacement@33", "SwapTernary@11", "SwapTernary@16",
            "SwapTernary@28", "SwapTernary@33",
        ])
    }

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

    /// Each mutant as `<operator>@<line>`, in discovery's order.
    private func mutants(in mappings: [SchemataMutationMapping]) -> [String] {
        mappings
            .flatMap(\.mutationSchemata)
            .map { "\($0.mutationOperatorId.rawValue)@\($0.position.line)" }
    }

}

private let sampleWithComplexDisableRules =
    """
        import Foundation

        // muter:disable
        func f() {
            doSomething(testableSideEffect: true)
        }

        // muter:enable
        func f() {
            doSomething(testableSideEffect: false)
        }

        // muter:disable
        struct IgnoreMe {

            func f() -> Bool {
                // muter:enable
                let b = a == 5
                // muter:disable
                let e = a != 1
                // muter:enable
                return a ? "true" : "false"
            }
        }
    """

private let sampleWithDisabledMutations =
    """
    import Foundation

    func f() {
        doSomething(testableSideEffect: true)
    }

    // muter:disable
    func f() {
        doSomething(testableSideEffect: false)
    }

    struct IgnoreMe {

        func f() {
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: false)
        }
    }
    """

private let sampleWithTopLevelDisable =
    """
    // muter:disable

    import Foundation

    func f() {
        doSomething(testableSideEffect: true)
    }

    func f() {
        doSomething(testableSideEffect: true)
        doSomething(testableSideEffect: false)
    }

    struct IgnoreMe {
        func f() {
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: true)
            doSomething(testableSideEffect: false)
        }
    }

    """
