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

    // The two copies have a mutant at one place. Their switch IDs named the file alone, so testing either mutant
    // switched on both.
    func test_givesFilesWithTheSameNameSwitchIDsOfTheirOwn() async throws {
        let paths = try makeSourceFiles(at: ["First/Module.swift", "Second/Module.swift"])
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        let ids = mappings.flatMap(\.mutationSchemata).map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2, "\(ids)")
        XCTAssertTrue(ids[0].hasPrefix("Module_\("First/Module.swift".stableHash)_"), ids[0])
        XCTAssertTrue(ids[1].hasPrefix("Module_\("Second/Module.swift".stableHash)_"), ids[1])
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

    // Only a few files are walked at once, and the next starts as one ends, so every file is walked once however many
    // there are.
    func test_discoversEveryFile_whenThereAreMoreThanAreWalkedAtOnce() async throws {
        let paths = try makeSourceFiles(at: (1 ... 25).map { "Module/File\($0).swift" })
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        XCTAssertEqual(mappings.map(\.filePath), paths.sorted())
        XCTAssertEqual(mappings.map(\.count), Array(repeating: 1, count: paths.count))
    }

    /// Writes a file with one mutant (`value < 0`) at each of `relativePaths`, under a new directory
    /// removed when the test finishes, which stands for the mutated project, and returns the files' paths.
    private func makeSourceFiles(at relativePaths: [String]) throws -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: root)

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

        XCTAssertEqual(mutatedLines, [5, 9])
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
