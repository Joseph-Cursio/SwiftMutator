@testable import muterCore
import SwiftParser
import SwiftSyntax
import XCTest

final class ApplySchemataTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = ApplySchemata()

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

    // Its mutants would still be tested, with no switch in the code, and every one would survive.
    func test_whenAFileWithMutantsCannotBeRead_thenThrowErrorNamingTheFile() async throws {
        let path = "/nonexistent/path/to/Missing.swift"
        let source = try sourceCode("func check(_ value: Int) -> Bool {\n    return value > 1\n}\n")
        let mapping = try XCTUnwrap(generateSchemataMappings(for: SourceCodeInfo(path: path, code: source)).first)
        state.sourceCodeByFilePath = [:]
        state.mutationMapping = [mapping]

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .literal(reason: ApplySchemata.couldNotRead(mapping))
        )
        let reason = ApplySchemata.couldNotRead(mapping)
        XCTAssertTrue(reason.contains(path), reason)
        XCTAssertTrue(reason.contains("every one would survive"), reason)
        XCTAssertFalse(writeFile.writeFileCalled)
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

    // Each mutant of a list is an `else if` inside the one before, and writing the file out recursed once per
    // level. The threads Swift concurrency runs this step on have stacks of about 512 KiB, which ran out at about
    // 520 mutants in one list in a debug build, and the run died with a bus error after discovery. 5,000 is past a
    // release build's limit too.
    func test_writesAListWithMoreMutantsThanAConcurrencyThreadsStackHolds() async throws {
        let path = "/path/to/Deep.swift"
        let source = try sourceCode("func deep(_ value: Int) -> Bool {\n    return value > 0\n}\n")
        let function = try XCTUnwrap(source.statements.first?.item.as(FunctionDeclSyntax.self))
        let body = try XCTUnwrap(function.body).statements
        var mapping = SchemataMutationMapping(filePath: path)
        for index in 1 ... 5_000 {
            try mapping.add(body, .make(
                filePath: path,
                syntaxMutation: "\n    return value > \(index)\n",
                position: MutationPosition(utf8Offset: index, line: index)
            ))
        }
        state.sourceCodeByFilePath[path] = source
        state.mutationMapping = [mapping]

        _ = try await sut.run(with: state)

        let written = try XCTUnwrap(writeFile.contentPassed)
        XCTAssertEqual(written.components(separatedBy: "] != nil {").count - 1, 5_000)
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
