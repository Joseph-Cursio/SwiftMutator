@testable import muterCore
import SwiftSyntax
import XCTest

extension DiscoverMutationPointsTests {
    func test_keepsFilesWithTheSameNameApart() async throws {
        // Two copies of one file in different directories. Merged by name, one copy's mapping
        // swallowed the other's, which put its mutants into the other copy, or nowhere.
        let paths = try makeSourceFiles(at: ["First/Module.swift", "Second/Module.swift"])
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            XCTFail("Expected mappings, got \(change)")
            return
        }

        XCTAssertEqual(mappings.map(\.filePath).sorted(), paths)
        for mapping in mappings {
            XCTAssertEqual(Set(mapping.mutationSchemata.map(\.filePath)), [mapping.filePath])
        }
    }

    // The two copies have mutants at one place, RelationalOperatorReplacement's swap and RelationalBoundary's, beside
    // the former's constant, which ReplaceBooleanValue leaves the value to. Their switch IDs named the file alone, so
    // testing either copy's mutant switched on the other copy's too.
    func test_givesFilesWithTheSameNameSwitchIDsOfTheirOwn() async throws {
        let paths = try makeSourceFiles(at: ["First/Module.swift", "Second/Module.swift"])
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            XCTFail("Expected mappings, got \(change)")
            return
        }

        let ids = mappings.flatMap(\.mutationSchemata).map(\.id)
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids).count, 6, "\(ids)")
        for id in ids.prefix(3) {
            XCTAssertTrue(id.hasPrefix("Module_\("First/Module.swift".stableHash)_"), id)
        }
        for id in ids.suffix(3) {
            XCTAssertTrue(id.hasPrefix("Module_\("Second/Module.swift".stableHash)_"), id)
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
            XCTFail("Expected mappings, got \(change)")
            return
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
            XCTFail("Expected mappings, got \(change)")
            return
        }

        XCTAssertEqual(mappings.map(\.filePath), paths.sorted())
        XCTAssertEqual(mappings.map(\.count), Array(repeating: 1, count: paths.count))
    }
}
