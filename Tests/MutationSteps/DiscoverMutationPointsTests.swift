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

    /// A file with a mutant that has no place for a switch, on line 3, and one that does, on line 4.
    private func droppingFile() throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropping-\(UUID().uuidString).swift")
        try """
        import Foundation
        let value = CommandLine.arguments.count
        guard let name = value > 1 ? "name" : nil else { exit(1) }
        print(name, value > 2)
        """.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
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

    // A project without a mutant has none of its own to name, so it's refused as a mutant that isn't there, not
    // reported as a failure to file.
    // A mutant nested in an opaque body is pruned once another operator mutates the body's own statements. A run under
    // skipOperators tested and reported it, so `--mutant` has to find it too.
    func test_aMutantNamed_thatOnlyTheConfiguredOperatorsKeep_isFound() async throws {
        let file = try opaqueBodyFile()
        state.sourceFileCandidates = [file]
        state.muterConfiguration = MuterConfiguration(skipOperators: [.swapTernary])
        state.runOptions = .make(
            mutationOperatorsList: .allOperators,
            mutant: MutantReference(path: file, line: 5, mutationOperatorId: .ror)
        )

        let result = try await sut.run(with: state)

        guard case let .mutationMappingsDiscovered(mappings) = try XCTUnwrap(result.first) else {
            return XCTFail("Expected mappings, got \(result)")
        }
        XCTAssertEqual(mappings.flatMap(\.mutationSchemata).map(\.mutationOperatorId), [.ror])
    }

    // Preparing a file rewrites it in the project's copy, so a second time would move every mutant in it.
    func test_aMutantNamed_thatOnlyTheConfiguredOperatorsKeep_preparesTheFileOnce() async throws {
        let file = try opaqueBodyFile()
        let preparations = PreparationCount()
        prepareCode.sourceCodeToReturn = {
            preparations.add()
            return muterCore.sourceCode(fromFileAt: $0).map { (source: $0, changes: .null) }
        }
        state.sourceFileCandidates = [file]
        state.muterConfiguration = MuterConfiguration(skipOperators: [.swapTernary])
        state.runOptions = .make(
            mutationOperatorsList: .allOperators,
            mutant: MutantReference(path: file, line: 5, mutationOperatorId: .ror)
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(preparations.count, 1)
    }

    func test_aMutantNamed_thatEveryOperatorsDiscoveryFinds_keepsThoseMutants() async throws {
        let file = try opaqueBodyFile()
        state.sourceFileCandidates = [file]
        state.muterConfiguration = MuterConfiguration(skipOperators: [.swapTernary])
        state.runOptions = .make(
            mutationOperatorsList: .allOperators,
            mutant: MutantReference(path: file, line: 7, mutationOperatorId: .swapTernary)
        )

        let result = try await sut.run(with: state)

        guard case let .mutationMappingsDiscovered(mappings) = try XCTUnwrap(result.first) else {
            return XCTFail("Expected mappings, got \(result)")
        }
        XCTAssertEqual(mappings.flatMap(\.mutationSchemata).map(\.mutationOperatorId), [.swapTernary])
    }

    func test_aChangeWithNoMutant_ofFewerOperators_namesThem() async throws {
        state.sourceFileCandidates = ["\(fixturesDirectory)/sourceWithoutMutableCode.swift"]
        state.mutationOperatorList = [.swapTernary, .ror]
        state.changeSelection = .make()

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected nothing to mutate")
        } catch let error as NothingToMutate {
            XCTAssertEqual(error.chosenOperators, [.swapTernary, .ror])
            XCTAssertTrue(
                error.description.contains(
                    "none of the operators chosen (SwapTernary, RelationalOperatorReplacement) mutates any code in it"
                ),
                error.description
            )
        }

        state.mutationOperatorList = .allOperators
        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected nothing to mutate")
        } catch let error as NothingToMutate {
            XCTAssertNil(error.chosenOperators)
            XCTAssertTrue(error.description.contains("no operator mutates any code in it"), error.description)
        }
    }

    // RelationalOperatorReplacement's swap of `a == b` is the mutant NegateConditional would make, so it isn't made
    // twice, and only while that operator is on.
    func test_aLoneEqualityCheck_isNegatedOnlyWithoutRelationalOperatorReplacement() async throws {
        let operators: (MutationOperatorList) async throws -> [MutationOperator.Id] = { list in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
            try "func f(a: Int, b: Int) { if a == b { print(a) } }\n".write(to: file, atomically: true, encoding: .utf8)
            self.addTeardownBlock { try? FileManager.default.removeItem(at: file) }
            self.state.sourceFileCandidates = [file.path]
            self.state.mutationOperatorList = list
            self.state.apply(try await self.sut.run(with: self.state))
            return self.state.mutationMapping.flatMap(\.mutationSchemata).map(\.mutationOperatorId)
        }

        let withAll = try await operators(.allOperators)
        XCTAssertEqual(withAll, [.ror])
        let alone = try await operators([.negateConditional])
        XCTAssertEqual(alone, [.negateConditional])
        let besideOthers = try await operators([.negateConditional, .logicalOperator])
        XCTAssertEqual(besideOthers, [.negateConditional])
    }

    // `--mutant` discovers every operator, and must still find the mutant a run with NegateConditional alone reported.
    func test_aMutantNamed_findsTheNegationOfALoneEqualityCheck() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        try "func f(a: Int, b: Int) { if a == b { print(a) } }\n".write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        state.sourceFileCandidates = [file.path]
        state.mutationOperatorList = .allOperators
        state.runOptions = .make(mutant: try MutantReference.parse("\(file.lastPathComponent):1:29 NegateConditional"))

        state.projectDirectoryURL = file.deletingLastPathComponent()
        state.mutatedProjectDirectoryURL = file.deletingLastPathComponent()

        state.apply(try await sut.run(with: state))
        state.apply(try await SelectMutant().run(with: state))

        let mutants = state.mutationMapping.flatMap(\.mutationSchemata)
        XCTAssertEqual(mutants.map(\.mutationOperatorId), [.negateConditional])
        XCTAssertEqual(mutants.map(\.position.line), [1])
        XCTAssertEqual(mutants.map(\.position.column), [29])
    }

    /// A file whose opaque getter holds a nested comparison, on line 5, and a ternary of its own, on line 7.
    private func opaqueBodyFile() throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).swift")
        try """
        struct Row: View {
            let count: Int
            let isExpanded: Bool
            private var toggle: some View {
                Button { } label: { Image(systemName: count == 1 ? "up" : "down") }
                    .padding()
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    func test_withAMutantNamed_aProjectWithoutMutants_refusesTheMutant() async throws {
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sourceWithoutMutableCode.swift",
        ]
        let reference = MutantReference(path: "Bar.swift", line: 12, column: 9)
        state.runOptions = .make(mutant: reference)

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected the mutant to be refused")
        } catch let refused as MutantRefused {
            XCTAssertEqual(refused, MutantRefused(reference: reference, reason: .notFound(nearby: [], files: 0)))
        }
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

    // The two copies have mutants at one place, RelationalOperatorReplacement's and RelationalBoundary's. Their switch
    // IDs named the file alone, so testing either copy's mutant switched on the other copy's too.
    func test_givesFilesWithTheSameNameSwitchIDsOfTheirOwn() async throws {
        let paths = try makeSourceFiles(at: ["First/Module.swift", "Second/Module.swift"])
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
        }

        let ids = mappings.flatMap(\.mutationSchemata).map(\.id)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids).count, 4, "\(ids)")
        for id in ids.prefix(2) {
            XCTAssertTrue(id.hasPrefix("Module_\("First/Module.swift".stableHash)_"), id)
        }
        for id in ids.suffix(2) {
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

        XCTAssertEqual(mutatedLines, [3, 3])
    }

    func test_shouldIgnoreMutantsWithoutCoverage_reportedThroughASymbolicLink() async throws {
        // How llvm-cov reports a file SwiftMutator found in `/private/tmp`: by its `/tmp` path.
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(directory)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(link)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3, 3])
    }

    func test_shouldIgnoreMutantsWithoutCoverage_inAFileReachedThroughASymbolicLink() async throws {
        let (directory, link) = try makeDirectoryWithSymbolicLink()
        try writeSourceWithAnUncoveredFunction(to: "\(directory)/Module.swift")

        state.sourceFileCandidates = ["\(link)/Module.swift"]
        state.projectCoverage = coverageMissingIsNegative(reportedAt: "\(directory)/Module.swift")

        let mutatedLines = try await discoveredMutantLines()

        XCTAssertEqual(mutatedLines, [3, 3])
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

        XCTAssertEqual(mutatedLines, [5, 5, 9, 9])
    }

    /// Mutants on line 1, in a function the tests never run, and on line 3, in one they do: each `<` or `>` gets
    /// RelationalOperatorReplacement's mutant and RelationalBoundary's.
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

private final class PreparationCount: @unchecked Sendable { // `stored` is behind `lock`
    private let lock = NSLock()
    private var stored = 0

    var count: Int { lock.withLock { stored } }

    func add() {
        lock.withLock { stored += 1 }
    }
}
