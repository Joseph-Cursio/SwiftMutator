@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

final class ApplySchemataTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = ApplySchemata()

    override func setUp() {
        super.setUp()
    }

    // MARK: - Lazy Loading Tests

    func test_appliesSchemataWithCachedSourceCode() async throws {
        // Setup: Create a mutation mapping with cached source
        let testFilePath = "\(fixturesDirectory)/sampleForDiscoveringMutations.swift"
        let sourceCode = Parser.parse(source: """
            func example() -> Bool {
                return true
            }
            """)

        state.sourceCodeByFilePath[testFilePath] = sourceCode

        // Create a simple mutation mapping
        let mapping = SchemataMutationMapping(filePath: testFilePath)

        state.mutationMapping = [mapping]

        // The sut should use cached source code
        let result = try await sut.run(with: state)
        XCTAssertEqual(result.count, 0) // ApplySchemata returns empty changes
    }

    func test_appliesSchemataWithLazyLoadedSourceCode() async throws {
        // Setup: Create a mutation mapping WITHOUT cached source
        // ApplySchemata should re-parse the file on demand
        let testFilePath = "\(fixturesDirectory)/sampleForDiscoveringMutations.swift"

        // Ensure source code is NOT cached
        state.sourceCodeByFilePath = [:]

        // Create a simple mutation mapping
        let mapping = SchemataMutationMapping(filePath: testFilePath)
        state.mutationMapping = [mapping]

        // The sut should re-parse the file when source is not cached
        let result = try await sut.run(with: state)
        XCTAssertEqual(result.count, 0) // ApplySchemata returns empty changes
    }

    func test_skipsFilesWithMissingSource() async throws {
        // Setup: Create a mutation mapping for a non-existent file
        let testFilePath = "/nonexistent/path/to/file.swift"

        state.sourceCodeByFilePath = [:]

        let mapping = SchemataMutationMapping(filePath: testFilePath)
        state.mutationMapping = [mapping]

        // Should skip missing files without crashing
        let result = try await sut.run(with: state)
        XCTAssertEqual(result.count, 0)
    }

    // Production never caches source (`DiscoverMutationPoints` passes an empty
    // dictionary), so this is the path every real run takes. The schemata are
    // keyed by syntax nodes from the tree discovery parsed; a freshly parsed
    // tree has different node identities and would match none of them, writing
    // the file back with no mutation switches at all.
    func test_writesMutationSwitchesWhenSourceIsNotCached() async throws {
        let path = "\(mutationExamplesDirectory)/NegateConditionals/sampleWithConditionalOperators.swift"
        let source = try XCTUnwrap(sourceCode(fromFileAt: path))
        let mappings = generateSchemataMappings(for: source)
        let schemata = mappings.flatMap(\.mutationSchemata)
        XCTAssertFalse(schemata.isEmpty, "fixture should contain mutation points")

        state.sourceCodeByFilePath = [:]
        state.mutationMapping = mappings

        _ = try await sut.run(with: state)

        let written = try XCTUnwrap(writeFile.contentPassed)
        for schema in schemata {
            XCTAssertTrue(
                written.contains(schema.id),
                "written source has no switch for mutant \(schema.id)"
            )
        }
    }

    func test_handlesEmptyMutationMapping() async throws {
        state.mutationMapping = []
        state.sourceCodeByFilePath = [:]

        let result = try await sut.run(with: state)
        XCTAssertEqual(result.count, 0)
    }

    func test_handlesMultipleMutationMappings() async throws {
        // Setup multiple mappings - some with cached source, some without
        let testFilePath1 = "\(fixturesDirectory)/sampleForDiscoveringMutations.swift"
        let testFilePath2 = "\(fixturesDirectory)/sample With Spaces For Discovering Mutations.swift"

        // Only cache one file
        let sourceCode = Parser.parse(source: "func test() {}")
        state.sourceCodeByFilePath[testFilePath1] = sourceCode

        let mapping1 = SchemataMutationMapping(filePath: testFilePath1)
        let mapping2 = SchemataMutationMapping(filePath: testFilePath2)
        state.mutationMapping = [mapping1, mapping2]

        // Should handle both cached and uncached files
        let result = try await sut.run(with: state)
        XCTAssertEqual(result.count, 0)
    }
}
