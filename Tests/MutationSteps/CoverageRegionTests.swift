@testable import muterCore
import TestingExtensions
import XCTest

final class CoverageRegionTests: MuterTestCase {
    private let region = Region.make(lineStart: 10, columnStart: 20, lineEnd: 14, columnEnd: 6)

    func test_containsNodeInside() {
        XCTAssertTrue(region.contains(.make(lineStart: 11, columnStart: 1, lineEnd: 11, columnEnd: 40)))
        XCTAssertTrue(region.contains(.make(lineStart: 10, columnStart: 20, lineEnd: 14, columnEnd: 6)))
    }

    func test_doesNotContainNodeAfterIt() {
        // Starts on a later line, at a column the region's start column is below. The old check,
        // which compared lines and columns separately, called this contained.
        XCTAssertFalse(region.contains(.make(lineStart: 20, columnStart: 30, lineEnd: 20, columnEnd: 40)))
        XCTAssertFalse(region.contains(.make(lineStart: 14, columnStart: 7, lineEnd: 14, columnEnd: 9)))
    }

    func test_doesNotContainNodeBeforeIt() {
        XCTAssertFalse(region.contains(.make(lineStart: 10, columnStart: 8, lineEnd: 10, columnEnd: 14)))
        XCTAssertFalse(region.contains(.make(lineStart: 2, columnStart: 1, lineEnd: 2, columnEnd: 5)))
    }

    func test_doesNotContainNodeOverlappingItsEdge() {
        XCTAssertFalse(region.contains(.make(lineStart: 9, columnStart: 1, lineEnd: 11, columnEnd: 1)))
        XCTAssertFalse(region.contains(.make(lineStart: 13, columnStart: 1, lineEnd: 15, columnEnd: 1)))
    }

    func test_decodesKind() throws {
        let json = Data("[[1, 2, 3, 4, 0, 0, 0, 3], [1, 2, 3, 4, 0, 0, 0, 2], [1, 2, 3, 4, 0], [1, 2, 3, 4, 0, 0, 0, 9]]".utf8)

        let kinds = try JSONDecoder().decode([Region].self, from: json).map(\.kind)

        XCTAssertEqual(kinds, [.gap, .skipped, .code, .other])
    }

    func test_onlyCodeAndSkippedRegionsCountAsWithoutCoverage() throws {
        let json = Data("""
        {"data": [{"functions": [{"filenames": ["/path/to/file.swift"], "regions": [
            [1, 1, 9, 2, 3, 0, 0, 0],
            [2, 1, 2, 9, 0, 0, 0, 0],
            [3, 1, 3, 9, 0, 0, 0, 1],
            [4, 1, 4, 9, 0, 0, 0, 2],
            [5, 1, 5, 9, 0, 0, 0, 3]
        ]}]}]}
        """.utf8)

        let coverage = try FunctionsCoverage(from: JSONDecoder().decode(LLVMCoverage.self, from: json))

        XCTAssertEqual(
            coverage.regionsForFile("/path/to/file.swift").map(\.lineStart),
            [2, 4]
        )
    }
}
