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

    // Counts that llvm-cov gets wrong are worked out from the ones the tests ran, so every function keeps all its
    // regions, in order: the first is its body.
    func test_eachFunctionKeepsItsCodeAndSkippedRegions_inOrder() throws {
        let json = Data("""
        {"data": [{"functions": [
            {"filenames": ["/path/to/file.swift"], "regions": [
                [1, 1, 9, 2, 3, 0, 0, 0], [2, 1, 2, 9, 0, 0, 0, 3], [3, 1, 3, 9, 2, 0, 0, 0]
            ]},
            {"filenames": ["/path/to/file.swift"], "regions": [[5, 1, 5, 9, 1, 0, 0, 0], [6, 1, 6, 9, 0, 0, 0, 2]]}
        ]}]}
        """.utf8)

        let coverage = try FunctionsCoverage(from: JSONDecoder().decode(LLVMCoverage.self, from: json))

        XCTAssertEqual(
            coverage.coverage(ofFile: "/path/to/file.swift").functions.map { $0.map(\.lineStart) },
            [[1, 3], [5, 6]]
        )
    }

    // A file an app shares with its extension is built into both, so each of its functions has a record in each binary,
    // under the module's name, with the same body: in this real export, where the tests ran only the app's. The
    // extension's would hide what the app's ran: the code its build left out of an `#if`, which the app's build kept,
    // and its copy of a closure, never called.
    func test_aFunctionsCopyThatNeverRan_hidesNothingAnotherCopyRan() throws {
        let coverage = try FunctionsCoverage(from: JSONDecoder().decode(LLVMCoverage.self, from: sharedFileExport()))

        let functions = coverage.coverage(ofFile: "/project/Shared.swift").functions
        XCTAssertEqual(
            functions.joined().include { $0.kind == .skipped }.map(\.span),
            [[2, 5, 4, 10], [6, 5, 6, 11], [2, 5, 2, 18]]
        )
        XCTAssertEqual(functions.filter { $0.first?.lineStart == 9 }.map { $0.map(\.executionCount) }, [[1]])
        XCTAssertEqual(functions.count, 3)
    }

    // When the tests ran both copies, only the code both builds left out of an `#if` is left out.
    func test_copiesThatBothRan_skipOnlyWhatBothSkip() throws {
        let coverage = try FunctionsCoverage(
            from: JSONDecoder().decode(LLVMCoverage.self, from: sharedFileExport(extensionRan: true))
        )

        XCTAssertEqual(
            coverage.coverage(ofFile: "/project/Shared.swift").functions.joined()
                .include { $0.kind == .skipped }.map(\.span),
            [[6, 5, 6, 11], [2, 5, 2, 18]]
        )
    }

    // A closure that is the whole of what makes it, as a property's initializer, shares its body, under a name that
    // starts with its maker's: it isn't a copy, and a closure that was made but never called reads so.
    func test_aClosureAndWhatMakesIt_areNotCopies() throws {
        let json = Data(#"""
        {"data": [{"functions": [
            {"name": "$s3App1SV1fSbycvpfi", "filenames": ["/project/S.swift"], "regions": [[2, 13, 2, 23, 1, 0, 0, 0]]},
            {"name": "$s3App1SV1fSbycvpfiSbycfU_", "filenames": ["/project/S.swift"], "regions": [
                [2, 13, 2, 23, 0, 0, 0, 0], [2, 15, 2, 21, 0, 0, 0, 2]
            ]}
        ]}]}
        """#.utf8)

        let coverage = try FunctionsCoverage(from: JSONDecoder().decode(LLVMCoverage.self, from: json))

        XCTAssertEqual(
            coverage.coverage(ofFile: "/project/S.swift").functions.map { $0.map(\.executionCount) },
            [[1], [0, 0]]
        )
    }

    /// llvm-cov's export of `Shared.swift` from an app and its extension, built with `EXTENSION`, after tests that
    /// ran the app's copy, and the extension's if `extensionRan`.
    ///
    ///     1 func sharedValue(_ x: Int) -> Bool {
    ///     2     #if EXTENSION
    ///     3     return x < 3
    ///     4     #else
    ///     5     return x > 0
    ///     6     #endif
    ///     7 }
    ///     8
    ///     9 let sharedClosure: (Int) -> Bool = { $0 >= 2 }
    private func sharedFileExport(extensionRan: Bool = false) -> Data {
        let ran = extensionRan ? 1 : 0
        return Data(#"""
        {"data": [{"functions": [
            {"name": "$s3App11sharedValueyS2iF", "filenames": ["/project/Shared.swift"], "regions": [
                [1, 35, 7, 2, 1, 0, 0, 0], [2, 5, 4, 10, 0, 0, 0, 2], [6, 5, 6, 11, 0, 0, 0, 2]
            ]},
            {"name": "$s3App13sharedClosureyS2icvpfiS2icfU_", "filenames": ["/project/Shared.swift"], "regions": [
                [9, 35, 9, 45, 1, 0, 0, 0]
            ]},
            {"name": "$s3Ext11sharedValueyS2iF", "filenames": ["/project/Shared.swift"], "regions": [
                [1, 35, 7, 2, \#(ran), 0, 0, 0], [2, 5, 2, 18, 0, 0, 0, 2], [4, 5, 6, 11, 0, 0, 0, 2]
            ]},
            {"name": "$s3Ext13sharedClosureyS2icvpfiS2icfU_", "filenames": ["/project/Shared.swift"], "regions": [
                [9, 35, 9, 45, \#(ran), 0, 0, 0]
            ]}
        ]}]}
        """#.utf8)
    }
}

private extension Region {
    var span: [Int] {
        [lineStart, columnStart, lineEnd, columnEnd]
    }
}
