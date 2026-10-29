@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

final class ExecutionCountsTests: XCTestCase {
    // Every way plain code changes a count: else-if, guard, switch with fallthrough and break, loops with continue
    // and break, do-catch with throw, and ternaries. These are llvm-cov's regions after `chain` ran for n of 20, 20,
    // 7, 3, 2, 2, 1 and 9. Every count that follows from others is set to 0, and is worked out again as llvm-cov's.
    func test_inPlainCode_theCountsThatFollowFromOthers_areLlvmCovs() throws {
        let regions = [
            [5, 52, 43, 2, 8], [6, 8, 6, 14, 8], [6, 15, 8, 6, 2], [8, 15, 8, 20, 6], [8, 21, 10, 6, 2],
            [10, 12, 12, 6, 4], [13, 22, 16, 6, 1], [16, 6, 43, 2, 7], [17, 12, 17, 13, 7], [18, 5, 20, 20, 0],
            [21, 5, 22, 26, 2], [23, 5, 24, 14, 5], [25, 6, 43, 2, 7], [27, 11, 27, 16, 70], [27, 17, 30, 6, 63],
            [29, 12, 29, 18, 63], [29, 19, 29, 31, 4], [29, 31, 30, 6, 59], [30, 6, 43, 2, 7], [31, 12, 33, 6, 14],
            [33, 6, 43, 2, 7], [33, 13, 33, 18, 14], [34, 39, 36, 6, 23], [35, 12, 35, 17, 23], [35, 18, 35, 27, 3],
            [35, 27, 36, 6, 20], [36, 6, 43, 2, 7], [37, 8, 40, 6, 7], [38, 12, 38, 18, 7], [38, 19, 38, 35, 1],
            [38, 35, 40, 6, 6], [39, 28, 39, 35, 3], [39, 38, 39, 45, 3], [40, 13, 42, 6, 1], [42, 6, 43, 2, 7],
        ]
        let direct = [
            [6, 15, 8, 6], [8, 21, 10, 6], [13, 22, 16, 6], [18, 5, 20, 20], [21, 5, 22, 26], [23, 5, 24, 14],
            [27, 11, 27, 16], [27, 17, 30, 6], [29, 19, 29, 31], [31, 12, 33, 6], [33, 13, 33, 18], [34, 39, 36, 6],
            [35, 18, 35, 27], [38, 19, 38, 35], [39, 28, 39, 35], [40, 13, 42, 6],
        ]

        let counts = try counts(in: """
        import Foundation

        struct Oops: Error {}

        public func chain(_ log: inout [String], _ n: Int) {
            if n > 10 {
                log.append("big")
            } else if n > 5 {
                log.append("mid")
            } else {
                log.append("small")
            }
            guard n > 1 else {
                log.append("one")
                return
            }
            switch n {
            case 0:
                log.append("zero")
                fallthrough
            case 2:
                log.append("two")
            default:
                break
            }
            var i = n
            while i > 0 {
                i -= 1
                if i == 3 { continue }
            }
            repeat {
                i += 1
            } while i < 2
            for k in 0 ..< n where k % 2 == 0 {
                if k > 6 { break }
            }
            do {
                if n == 7 { throw Oops() }
                log.append(n > 8 ? "eight" : "seven")
            } catch {
                log.append("caught")
            }
        }
        """, coverage: .llvmCov([zeroing(regions, except: direct)]))

        XCTAssertEqual(counts, inOrderOfStart(regions))
    }

    // In a result builder, llvm-cov counts the code after an `if` that was never true as never run, and gives the
    // `else` after it, which never ran, a negative count, shown as the largest one. These are its regions when the
    // tests call `pick(sink, false, true, 3)` and `pick(sink, false, true, 1)`.
    func test_inAResultBuilder_theCountsAfterAnIf_areWorkedOutAgain() throws {
        let negative = 9_223_372_036_854_775_807
        let regions = [
            [4, 76, 14, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 14, 2, 0], [8, 8, 8, 9, 0], [8, 10, 10, 6, 2],
            [9, 27, 9, 32, 1], [9, 35, 9, 42, 1], [10, 12, 12, 6, negative], [11, 27, 11, 33, 0],
            [11, 36, 11, 42, negative], [13, 23, 13, 29, 1], [13, 32, 13, 38, negative],
        ]

        let counts = try counts(in: """
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
        """, coverage: .llvmCov([regions]))

        XCTAssertEqual(counts, [
            [4, 76, 14, 2, 2], [5, 8, 5, 9, 2], [5, 10, 7, 6, 0], [7, 6, 14, 2, 2], [8, 8, 8, 9, 2], [8, 10, 10, 6, 2],
            [9, 27, 9, 32, 1], [9, 35, 9, 42, 1], [10, 12, 12, 6, 0], [11, 27, 11, 33, 0], [11, 36, 11, 42, 0],
            [13, 23, 13, 29, 1], [13, 32, 13, 38, 1],
        ])
    }

    // An `if` with an `else` and a `switch` are counted right; the code after an `if let` and the ternary in it
    // aren't. These are llvm-cov's regions after `shown` ran for (20, 1), (0, nil) and (3, nil).
    func test_inAResultBuilder_onlyTheWrongCountsChange() throws {
        let regions = [
            [4, 66, 20, 2, 3], [5, 8, 5, 14, 3], [5, 15, 7, 6, 1], [7, 12, 9, 6, 2], [10, 12, 10, 13, 3],
            [11, 5, 12, 26, 1], [13, 5, 14, 27, 2], [15, 6, 20, 2, 3], [16, 14, 18, 6, 1], [18, 6, 20, 2, 2],
            [19, 26, 19, 31, 2], [19, 34, 19, 40, 0],
        ]

        let counts = try counts(in: """
        import Foundation

        @ListBuilder
        public func shown(_ sink: Sink, _ n: Int, _ v: Int?) -> [String] {
            if n > 10 {
                sink.note("big")
            } else {
                sink.note("small")
            }
            switch n {
            case 0:
                sink.note("zero")
            default:
                sink.note("other")
            }
            if let v {
                sink.note("v \\(v)")
            }
            sink.note(v == nil ? "nil" : "some")
        }
        """, coverage: .llvmCov([regions]))

        XCTAssertEqual(counts, [
            [4, 66, 20, 2, 3], [5, 8, 5, 14, 3], [5, 15, 7, 6, 1], [7, 12, 9, 6, 2], [10, 12, 10, 13, 3],
            [11, 5, 12, 26, 1], [13, 5, 14, 27, 2], [15, 6, 20, 2, 3], [16, 14, 18, 6, 1], [18, 6, 20, 2, 3],
            [19, 26, 19, 31, 2], [19, 34, 19, 40, 1],
        ])
    }

    // Tests that run at once lose counts, so a switch's cases can add up to more than the switch ran: here the first
    // case's count of 3 is made 4. The count after the switch, set to 0, is worked out as llvm-cov's: what the cases
    // that don't return add up to, 4, not what the switch ran less what returned, 3.
    func test_countsThatDontAddUp_areWorkedOutAsLlvmCovDoes() throws {
        let regions = [
            [1, 35, 11, 2, 10], [2, 12, 2, 13, 10], [3, 5, 4, 17, 4], [5, 5, 6, 17, 3], [7, 5, 8, 14, 4],
            [9, 6, 10, 13, 4],
        ]

        let counts = try counts(in: """
        public func kind(_ n: Int) -> Int {
            switch n {
            case 0:
                return 0
            case 1:
                return 1
            default:
                break
            }
            return 2
        }
        """, coverage: .llvmCov([zeroing(regions, except: [[3, 5, 4, 17], [5, 5, 6, 17], [7, 5, 8, 14]])]))

        XCTAssertEqual(counts, inOrderOfStart(regions))
    }

    // After a call that can throw, Swift starts a region with the count before less the times it threw, which is in
    // llvm-cov's counts. An `else if` ends where its `if` does, and the count there is the whole `if`'s. These are
    // llvm-cov's regions after `load` was called 5 times, 2 of them `quick`, of which 1 threw.
    func test_afterATry_theCountIsTheOneBeforeLessTheTimesItThrew() throws {
        let regions = [
            [1, 63, 8, 2, 5], [2, 8, 2, 13, 5], [2, 14, 4, 6, 2], [3, 24, 4, 6, 1], [4, 15, 4, 27, 3],
            [4, 28, 6, 6, 1], [6, 6, 7, 22, 3],
        ]

        let counts = try counts(in: """
        public func load(_ path: String, _ quick: Bool) throws -> Int {
            if quick {
                try check(path)
            } else if path.isEmpty {
                return 0
            }
            return path.count
        }
        """, coverage: .llvmCov([zeroing(regions, except: [[2, 14, 4, 6], [3, 24, 4, 6], [4, 28, 6, 6]])]))

        XCTAssertEqual(counts, inOrderOfStart(regions))
    }

    // An implicit closure, here an `@autoclosure` argument and a local `lazy` variable's initial value, is a function
    // of its own, which its regions follow from, not from the function that holds it. These are llvm-cov's regions
    // after `autoPartial` ran with 3 and with -5, logging only the first, and `lazyPartial` with 9, using `v`, and 1.
    func test_anImplicitClosuresCounts_followFromItsOwn() throws {
        let regions = [
            [[10, 57, 13, 2, 2]],
            [[11, 15, 11, 50, 1], [11, 23, 11, 26, 1], [11, 29, 11, 50, 0], [11, 40, 11, 43, 0], [11, 46, 11, 49, 0]],
            [[15, 55, 21, 2, 2], [17, 8, 17, 11, 2], [17, 12, 19, 6, 1], [19, 6, 20, 13, 1]],
            [[16, 18, 16, 50, 1], [16, 26, 16, 31, 1], [16, 34, 16, 50, 0], [16, 44, 16, 45, 0], [16, 48, 16, 49, 0]],
        ]
        let direct = [[11, 23, 11, 26], [11, 40, 11, 43], [17, 12, 19, 6], [16, 26, 16, 31], [16, 44, 16, 45]]

        let counts = try counts(in: """
        public final class Logger {
            public var enabled = false
            public var lines: [String] = []
            public init() {}
            public func debug(_ message: @autoclosure () -> String) {
                if enabled { lines.append(message()) }
            }
        }

        public func autoPartial(_ log: Logger, _ x: Int) -> Int {
            log.debug(x > 0 ? "p" : (x == -5 ? "m" : "o"))
            return x
        }

        public func lazyPartial(_ x: Int, _ use: Bool) -> Int {
            lazy var v = x > 5 ? x - 5 : (x < -5 ? 1 : 2)
            if use {
                return v
            }
            return 0
        }
        """, coverage: .llvmCov(regions.map { zeroing($0, except: direct) }))

        XCTAssertEqual(counts, inOrderOfStart(Array(regions.joined())))
    }

    // Tests that run at once lose counts: here `first` ran 3 times, and its count reads 2, so the count after the
    // `guard`, worked out from it, reads 0 though the `default` in it ran. Code that holds code that ran, ran.
    func test_aRegionThatHoldsCodeThatRan_ran_thoughItsCountLostUpdates() throws {
        let regions = [
            [3, 39, 13, 2, 2], [4, 33, 6, 6, 2], [6, 6, 13, 2, 0], [7, 12, 7, 13, 0], [8, 5, 9, 17, 0],
            [10, 5, 11, 17, 1],
        ]

        let walked = try Self.executionCounts(in: """
        import Foundation

        public func first(_ xs: [Int]) -> Int {
            guard let x = xs.first else {
                return 0
            }
            switch x {
            case 1:
                return 1
            default:
                return 2
            }
        }
        """, coverage: .llvmCov([regions]))

        XCTAssertEqual(counts(of: walked), regions)
        XCTAssertEqual(walked.regionsRan, [true, true, true, false, false, true])
    }

    // A negative count counts as run: tests that run at once lose counts, as here, where `drain`'s loop body ran 5
    // times and reads 0, which makes the count at its end, and its condition's, negative. Swift's count after the
    // `repeat`, 1, leaves out its `break`, so it's worked out again as 2, but a count that stays some isn't one Swift
    // got wrong, and says nothing about the counts it holds. These are llvm-cov's regions for `drain` with 2 and 5,
    // with the body's lost counts.
    func test_aNegativeCount_thatFollowsACountWorkedOutAgainAsMuchTheSame_ran() throws {
        let negative = 9_223_372_036_854_775_807
        let regions = [
            [3, 52, 13, 2, 2], [5, 12, 8, 6, 0], [7, 12, 7, 18, 0], [7, 19, 7, 28, 1], [7, 28, 8, 6, negative],
            [8, 6, 13, 2, 1], [8, 13, 8, 18, negative], [9, 11, 9, 16, 3], [9, 17, 11, 6, 2], [11, 6, 13, 2, 1],
        ]

        let walked = try Self.executionCounts(in: """
        import Foundation

        public func drain(_ n: Int, _ log: inout [String]) {
            var i = 0
            repeat {
                i += 1
                if i == n { break }
            } while i < 3
            while i < n {
                i += 1
            }
            log.append("done")
        }
        """, coverage: .llvmCov([regions]))

        XCTAssertEqual(counts(of: walked)[5], [8, 6, 13, 2, 2])
        XCTAssertEqual(walked.regionsRan[6], true)
    }

    // A chain of ternaries is one flat sequence, and the walk goes a call deeper for each, up to a limit well within
    // the 512 KB stack that discovery's threads have.
    func test_aLongChainOfTernaries_isWalkedOnADiscoveryThreadsStack() throws {
        let chain = (0 ..< 400).map { "c[\($0)] ? v[\($0)] : " }.joined()
        let source = "public func pick(_ c: [Bool], _ v: [Int]) -> Int {\n    return \(chain)-1\n}"
        let finished = expectation(description: "walked")

        let thread = Thread {
            _ = try? Self.executionCounts(in: source, coverage: .llvmCov([[[1, 50, 3, 2, 1]]]))
            finished.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()

        wait(for: [finished], timeout: 60)
    }

    // The walk goes a call deeper for each expression in another, and stops well within a discovery thread's stack:
    // the ternary at the bottom of a long chain of calls keeps llvm-cov's counts.
    func test_codeDeeperThanTheWalkGoes_keepsLlvmCovsCounts() throws {
        let negative = 9_223_372_036_854_775_807
        let chain = String(repeating: ".k()", count: 150)
        let source = """
        @ListBuilder
        func deep(_ a: Bool, _ n: Int) -> [String] {
            if a {
                "a"
            }
            x.k(n > 0 ? "p" : "q")\(chain)
        }
        """

        let walked = try counts(in: source, coverage: .llvmCov([
            [
                [2, 44, 7, 2, 2], [3, 8, 3, 9, 2], [3, 10, 5, 6, 0], [5, 6, 7, 2, 0], [6, 17, 6, 20, 2],
                [6, 23, 6, 26, negative],
            ],
        ]))

        XCTAssertEqual(walked, [
            [2, 44, 7, 2, 2], [3, 8, 3, 9, 2], [3, 10, 5, 6, 0], [5, 6, 7, 2, 2], [6, 17, 6, 20, 2],
            [6, 23, 6, 26, negative],
        ])
    }

    // A type's property whose value is a closure is made with each instance, but the count of the code that makes it
    // can read 0 though it ran, as for a struct's memberwise init: the closure was made if it was called.
    func test_aPropertysClosure_wasMadeIfItWasCalled() throws {
        let walked = try Self.executionCounts(in: """
        public struct Rule {
            let check: (Int) -> Bool = { $0 > 7 ? true : false }
            var name: String
        }
        """, coverage: .llvmCov([
            [[2, 32, 2, 57, 0]],
            [[2, 32, 2, 57, 2], [2, 43, 2, 47, 1], [2, 50, 2, 55, 1]],
        ]))

        XCTAssertEqual(counts(of: walked), [[2, 32, 2, 57, 2], [2, 32, 2, 57, 2], [2, 43, 2, 47, 1], [2, 50, 2, 55, 1]])
        XCTAssertEqual(walked.regionsRan, [true, true, true, true])
    }

    private func counts(in source: String, coverage: FileCoverage) throws -> [[Int]] {
        try counts(of: Self.executionCounts(in: source, coverage: coverage))
    }

    private static func executionCounts(in source: String, coverage: FileCoverage) throws -> ExecutionCounts {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "/path/to/file", tree: tree)
        return ExecutionCounts(coverage: coverage, source: tree) { position in
            let location = converter.location(for: position)
            return ExecutionCounts.Point(line: location.line, column: location.column)
        }
    }

    private func counts(of counts: ExecutionCounts) -> [[Int]] {
        counts.countedRegions.map {
            [$0.lineStart, $0.columnStart, $0.lineEnd, $0.columnEnd, $0.executionCount]
        }
    }

    /// A function's `regions` with the count of every one but the first and those in `direct` set to 0.
    private func zeroing(_ regions: [[Int]], except direct: [[Int]]) -> [[Int]] {
        regions.enumerated().map { index, region in
            index == 0 || direct.contains(Array(region.prefix(4))) ? region : Array(region.prefix(4)) + [0]
        }
    }

    /// In `ExecutionCounts.countedRegions`' order: by start, and of two with the same start, the longer first.
    private func inOrderOfStart(_ regions: [[Int]]) -> [[Int]] {
        regions.sorted { ($0[0], $0[1], $1[2], $1[3]) < ($1[0], $1[1], $0[2], $0[3]) }
    }
}
