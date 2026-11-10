@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

extension ExecutionCountsTests {
    func counts(in source: String, coverage: FileCoverage) throws -> [[Int]] {
        try counts(of: Self.executionCounts(in: source, coverage: coverage))
    }

    static func executionCounts(in source: String, coverage: FileCoverage) throws -> ExecutionCounts {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "/path/to/file", tree: tree)
        return ExecutionCounts(coverage: coverage, source: tree) { position in
            let location = converter.location(for: position)
            return ExecutionCounts.Point(line: location.line, column: location.column)
        }
    }

    func counts(of counts: ExecutionCounts) -> [[Int]] {
        counts.countedRegions.map {
            [$0.lineStart, $0.columnStart, $0.lineEnd, $0.columnEnd, $0.executionCount]
        }
    }

    /// A function's `regions` with the count of every one but the first and those in `direct` set to 0.
    func zeroing(_ regions: [[Int]], except direct: [[Int]]) -> [[Int]] {
        regions.enumerated().map { index, region in
            index == 0 || direct.contains(Array(region.prefix(4))) ? region : Array(region.prefix(4)) + [0]
        }
    }

    /// In `ExecutionCounts.countedRegions`' order: by start, and of two with the same start, the longer first.
    func inOrderOfStart(_ regions: [[Int]]) -> [[Int]] {
        regions.sorted { ($0[0], $0[1], $1[2], $1[3]) < ($1[0], $1[1], $0[2], $0[3]) }
    }
}
