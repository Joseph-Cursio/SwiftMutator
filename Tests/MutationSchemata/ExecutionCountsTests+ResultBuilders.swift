@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

extension ExecutionCountsTests {
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
}
