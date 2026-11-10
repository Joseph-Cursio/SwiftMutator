@testable import muterCore
import SwiftSyntax
import XCTest

extension DiscoverMutationPointsTests {
    func test_shouldIgnoreMutantsWithoutCoverage() async throws {
        let (directory, _) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(directory)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(directory)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3, 3, 3])
    }

    func test_shouldIgnoreMutantsWithoutCoverage_reportedThroughASymbolicLink() async throws {
        // How llvm-cov reports a file SwiftMutator found in `/private/tmp`: by its `/tmp` path.
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(directory)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(link)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3, 3, 3])
    }

    func test_shouldIgnoreMutantsWithoutCoverage_inAFileReachedThroughASymbolicLink() async throws {
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(link)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(directory)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3, 3, 3])
    }

    // A file an app shares with its extension has a copy of each function in each binary: in this real export, where
    // the tests ran only the app's. The extension's copies, never run, leave out none of the code the app's ran: what
    // the extension's build left out of an `#if`, and its closure.
    func test_mutantsInCodeOneBinarysCopyRan_areKept() async throws {
        let (directory, _) = try makeDirectoryWithSymbolicLink()
        let path = "\(directory)/Shared.swift"
        try """
        func sharedValue(_ x: Int) -> Bool {
            #if EXTENSION
            return x < 3
            #else
            return x > 0
            #endif
        }

        let sharedClosure: (Int) -> Bool = { $0 >= 2 }
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let export = Data(#"""
        {"data": [{"functions": [
            {"name": "$s3App11sharedValueyS2iF", "filenames": ["\#(path)"], "regions": [
                [1, 35, 7, 2, 1, 0, 0, 0], [2, 5, 4, 10, 0, 0, 0, 2], [6, 5, 6, 11, 0, 0, 0, 2]
            ]},
            {"name": "$s3App13sharedClosureyS2icvpfiS2icfU_", "filenames": ["\#(path)"], "regions": [
                [9, 35, 9, 45, 1, 0, 0, 0]
            ]},
            {"name": "$s3Ext11sharedValueyS2iF", "filenames": ["\#(path)"], "regions": [
                [1, 35, 7, 2, 0, 0, 0, 0], [2, 5, 2, 18, 0, 0, 0, 2], [4, 5, 6, 11, 0, 0, 0, 2]
            ]},
            {"name": "$s3Ext13sharedClosureyS2icvpfiS2icfU_", "filenames": ["\#(path)"], "regions": [
                [9, 35, 9, 45, 0, 0, 0, 0]
            ]}
        ]}]}
        """#.utf8)

        state.sourceFileCandidates = [path]
        state.projectCoverage = try Coverage.make(
            functionsCoverage: FunctionsCoverage(from: JSONDecoder().decode(LLVMCoverage.self, from: export))
        )

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [5, 5, 5, 9, 9])
    }

    /// Mutants on line 1, in a function the tests never run, and on line 3, in one they do: each `<` or `>` gets
    /// RelationalOperatorReplacement's two and RelationalBoundary's, as ReplaceBooleanValue leaves a comparison to the
    /// first.
    func writeSourceWithAnUncoveredFunction(to path: String) throws {
        try """
        func isNegative(_ value: Int) -> Bool { value < 0 }
        func isPositive(_ value: Int) -> Bool {
            value > 0
        }
        """.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Coverage in which only `isNegative`'s body never ran, reported for the file at `path`.
    func coverageMissingIsNegative(reportedAt path: String) -> Coverage {
        let isNegativeBody = Region.make(lineStart: 1, columnStart: 39, lineEnd: 1, columnEnd: 52)

        return Coverage.make(
            functionsCoverage: FunctionsCoverage(
                from: LLVMCoverage(data: [
                    .init(functions: [Function(filenames: [path], regions: [isNegativeBody])]),
                ])
            )
        )
    }

    func discoveredMutantLines() async throws -> [Int] {
        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            XCTFail("Expected mappings, got \(change)")
            return []
        }

        return mappings.flatMap(\.mutationSchemata).map(\.position.line).sorted()
    }
}
