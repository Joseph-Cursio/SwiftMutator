@testable import muterCore
import SwiftSyntax
import XCTest

final class DiscoverMutationPointsTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = DiscoverMutationPoints()

    override func setUp() {
        super.setUp()

        state.mutationOperatorList = .allOperators
        prepareCode.sourceCodeToReturn = {
            muterCore.sourceCode(fromFileAt: $0).map {
                (
                    source: $0,
                    changes: .null
                )
            }
        }
    }

    func test_discoversMutations() async throws {
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sampleForDiscoveringMutations.swift",
            "\(fixturesDirectory)/sample With Spaces For Discovering Mutations.swift",
        ]

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, get \(change)")
        }

        XCTAssertEqual(mappings.count, 2)

        let sampleForDiscoveringMutations = mappings
            .first { $0.fileName.contains("sampleForDiscoveringMutations") }

        let ternaryOperatorSchemata = sampleForDiscoveringMutations?
            .mutationSchemata
            .include { $0.mutationOperatorId == .swapTernary }

        XCTAssertEqual(ternaryOperatorSchemata?.count, 1)

        let rorSchemata = sampleForDiscoveringMutations?
            .mutationSchemata
            .include { $0.mutationOperatorId == .ror }

        XCTAssertEqual(rorSchemata?.count, 2)

        let sampleWithSpacesForDiscoveringMutations = mappings
            .first { $0.fileName.contains("sample With Spaces For Discovering Mutations") }

        let removeSideEffectsSchemata = sampleWithSpacesForDiscoveringMutations?
            .mutationSchemata
            .include { $0.mutationOperatorId == .removeSideEffects }

        XCTAssertEqual(removeSideEffectsSchemata?.count, 2)
    }

    func test_shouldIgnoreUknownOperators() async throws {
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sourceWithoutMutableCode.swift",
        ]

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .noMutationPointsDiscovered
        )
    }

    // MARK: - Files with the same name

    func test_keepsFilesWithTheSameNameApart() async throws {
        // Two copies of one file in different directories. Merged by name, one copy's mapping
        // swallowed the other's, which put its mutants into the other copy, or nowhere.
        let paths = try makeSourceFiles(at: ["First/Module.swift", "Second/Module.swift"])
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        XCTAssertEqual(mappings.map(\.filePath).sorted(), paths)
        for mapping in mappings {
            XCTAssertEqual(Set(mapping.mutationSchemata.map(\.filePath)), [mapping.filePath])
        }
    }

    func test_returnsFilesInPathOrder() async throws {
        // Mutants are tested in this order, so it has to be the same on every run for two runs to be
        // compared mutant by mutant. Discovery finishes files in whatever order its threads do.
        let paths = try makeSourceFiles(at: (1 ... 8).map { "Module\($0)/File\(9 - $0).swift" })
        state.sourceFileCandidates = paths.reversed()

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        XCTAssertEqual(mappings.map(\.filePath), paths)
    }

    /// Writes a file with one mutant (`value < 0`) at each of `relativePaths`, under a new directory
    /// removed when the test finishes, and returns the files' paths.
    private func makeSourceFiles(at relativePaths: [String]) throws -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }

        return try relativePaths.map { relativePath in
            let path = "\(root)/\(relativePath)"
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                withIntermediateDirectories: true
            )
            try "func isNegative(_ value: Int) -> Bool { value < 0 }\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
    }

    // MARK: - Large Codebase Tests (Parallel Processing)

    func test_discoversMultipleFilesInParallel() async throws {
        // Test that multiple files are processed correctly with parallel batching
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sampleForDiscoveringMutations.swift",
            "\(fixturesDirectory)/sample With Spaces For Discovering Mutations.swift",
        ]

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        // Verify all files were processed
        XCTAssertEqual(mappings.count, 2)

        // Verify mutations were found in both files
        let fileNames = mappings.map { $0.fileName }
        XCTAssertTrue(fileNames.contains { $0.contains("sampleForDiscoveringMutations") })
        XCTAssertTrue(fileNames.contains { $0.contains("sample With Spaces") })
    }

    func test_returnsEmptySourceCodeDictionary() async throws {
        // The fix passes an empty dictionary to prevent memory exhaustion
        // ApplySchemata should re-parse files on demand
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sampleForDiscoveringMutations.swift",
        ]

        let result = try await sut.run(with: state)

        // Check that sourceCodeParsed change contains empty dictionary
        let sourceCodeChange = result.first { change in
            if case .sourceCodeParsed = change { return true }
            return false
        }

        guard case let .sourceCodeParsed(sourceCode) = sourceCodeChange else {
            return XCTFail("Expected sourceCodeParsed change")
        }

        XCTAssertTrue(sourceCode.isEmpty, "Source code dictionary should be empty to prevent memory exhaustion")
    }

    func test_handlesEmptyFileCandidates() async throws {
        state.sourceFileCandidates = []

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .noMutationPointsDiscovered
        )
    }

    func test_handlesNonSwiftFiles() async throws {
        // Non-swift files should be filtered out
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/someFile.txt",
            "\(fixturesDirectory)/sampleForDiscoveringMutations.swift",
        ]

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        // Only Swift files should be processed
        XCTAssertEqual(mappings.count, 1)
        XCTAssertTrue(mappings[0].fileName.hasSuffix(".swift"))
    }

    // MARK: - Coverage

    func test_shouldIgnoreMutantsWithoutCoverage() async throws {
        let (directory, _) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(directory)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(directory)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3])
    }

    func test_shouldIgnoreMutantsWithoutCoverage_reportedThroughASymbolicLink() async throws {
        // How llvm-cov reports a file SwiftMutator found in `/private/tmp`: by its `/tmp` path.
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(directory)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(link)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3])
    }

    func test_shouldIgnoreMutantsWithoutCoverage_inAFileReachedThroughASymbolicLink() async throws {
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(link)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(directory)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3])
    }

    /// A mutant on line 1, in a function the tests never run, and one on line 3, in one they do.
    private func writeSourceWithAnUncoveredFunction(to path: String) throws {
        try """
        func isNegative(_ value: Int) -> Bool { value < 0 }
        func isPositive(_ value: Int) -> Bool {
            value > 0
        }
        """.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Coverage in which only `isNegative`'s body never ran, reported for the file at `path`.
    private func coverageMissingIsNegative(reportedAt path: String) -> Coverage {
        let isNegativeBody = Region.make(lineStart: 1, columnStart: 39, lineEnd: 1, columnEnd: 52)

        return Coverage.make(
            functionsCoverage: FunctionsCoverage(
                from: LLVMCoverage(data: [
                    .init(functions: [Function(filenames: [path], regions: [isNegativeBody])]),
                ])
            )
        )
    }

    private func discoveredMutantLines() async throws -> [Int] {
        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            XCTFail("Expected mappings, got \(change)")
            return []
        }

        return mappings.flatMap(\.mutationSchemata).map(\.position.line).sorted()
    }
}
