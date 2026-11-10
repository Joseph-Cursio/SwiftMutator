@testable import muterCore
import SwiftSyntax
import XCTest

final class DiscoverMutationPointsTests: MuterTestCase {
    let state = MutationTestState()
    let sut = DiscoverMutationPoints()

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
            XCTFail("Expected mappings, get \(change)")
            return
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

        XCTAssertEqual(rorSchemata?.count, 4)

        let sampleWithSpacesForDiscoveringMutations = mappings
            .first { $0.fileName.contains("sample With Spaces For Discovering Mutations") }

        let removeSideEffectsSchemata = sampleWithSpacesForDiscoveringMutations?
            .mutationSchemata
            .include { $0.mutationOperatorId == .removeSideEffects }

        XCTAssertEqual(removeSideEffectsSchemata?.count, 2)
    }

    func test_saysWhichMutantsItDropped() async throws {
        let file = try droppingFile()
        state.sourceFileCandidates = [file]

        let result = try await sut.run(with: state)

        let dropped = try XCTUnwrap(result.lazy.compactMap { change -> [DroppedMutant]? in
            guard case let .mutantsDropped(dropped) = change else { return nil }
            return dropped
        }.first)
        XCTAssertEqual(Set(dropped.map(\.position.line)), [3])
        XCTAssertEqual(Set(dropped.map(\.mutationOperatorId)), [.ror, .relationalBoundary, .swapTernary])
        XCTAssertEqual(Set(dropped.map(\.reason)), [.noPlaceForASwitch])
    }

    func test_aMutantNamed_saysNoneWasDropped() async throws {
        let file = try droppingFile()
        state.sourceFileCandidates = [file]
        state.runOptions = Run.Options(
            skipCoverage: true,
            skipUpdateCheck: true,
            configurationURL: nil,
            mutant: MutantReference(path: file, line: 4, column: nil)
        )

        let result = try? await sut.run(with: state)

        XCTAssertFalse((result ?? []).contains { change in
            if case .mutantsDropped = change { return true }
            return false
        })
    }

    /// Mutants on lines 3 and 7, active on macOS, and on line 5, which isn't.
    let ifsAroundMutants = """
    func f(_ a: Int, _ b: Int) -> Bool {
        #if os(macOS)
        let first = a > b
        #else
        let first = a < b
        #endif
        return first && a >= b
    }
    """

    /// Writes a file with one mutant (`value < 0`) at each of `relativePaths`, under a new directory
    /// removed when the test finishes, which stands for the mutated project, and returns the files' paths.
    func makeSourceFiles(at relativePaths: [String]) throws -> [String] {
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
}
