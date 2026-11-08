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

    func test_aMutantInAnInactiveIf_isDropped_andCounted() async throws {
        let file = try file(withLines: ifsAroundMutants)
        state.sourceFileCandidates = [file]
        state.buildConditions = macOSBuild

        let result = try await sut.run(with: state)

        XCTAssertEqual(try mutantLines(in: result), [3, 7])
        XCTAssertEqual(Set(try droppedMutants(in: result).map(\.position.line)), [5])
        XCTAssertEqual(Set(try droppedMutants(in: result).map(\.reason)), [.inInactiveIfConfig])
    }

    func test_withoutBuildConditions_everyBranchKeepsItsMutants() async throws {
        let file = try file(withLines: ifsAroundMutants)
        state.sourceFileCandidates = [file]

        let result = try await sut.run(with: state)

        XCTAssertEqual(try mutantLines(in: result), [3, 5, 7])
        XCTAssertFalse(result.contains { change in
            if case .mutantsDropped = change { return true }
            return false
        })
    }

    // Each operator reports the node it changes in its own way, so each is checked: RemoveSideEffects replaces a whole
    // statement list, and SwapTernary and the like the expression.
    func test_everyOperatorsMutants_inAnInactiveIf_areDropped() async throws {
        let body = """
            var total = 0
            total = a + 1
            print(flag && a > 1)
            let chosen = flag ? 1 : 2
            if !flag { total = 3 }
            let isDone = !flag || true
            do { record(total) }
            return total + chosen
        """
        let file = try file(withLines: """
        func f(_ a: Int, _ flag: Bool) -> Int {
            #if os(iOS)
        \(body)
            #else
        \(body)
            #endif
        }
        """)
        state.sourceFileCandidates = [file]
        state.buildConditions = macOSBuild

        let result = try await sut.run(with: state)

        let inactive = 3...10
        let active = 12...19
        let lines = try mutantLines(in: result)
        XCTAssertTrue(lines.allSatisfy(active.contains), "\(lines)")
        let dropped = try droppedMutants(in: result)
        XCTAssertTrue(dropped.allSatisfy { inactive.contains($0.position.line) }, "\(dropped.map(\.line))")
        XCTAssertEqual(Set(dropped.map(\.reason)), [.inInactiveIfConfig])

        // The two branches are the same code, so what the build compiles is what was dropped, operator by operator.
        let mappings = try XCTUnwrap(result.lazy.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first)
        let kept = mappings.flatMap(\.mutationSchemata).map(\.mutationOperatorId)
        XCTAssertEqual(Set(dropped.map(\.mutationOperatorId)), Set(kept))
        XCTAssertEqual(dropped.count, kept.count)
        XCTAssertEqual(Set(kept), Set(MutationOperatorList.allOperators))
    }

    // Tagged off, it isn't a mutant discovery found.
    func test_aMutantTaggedOff_inAnInactiveIf_isNotCounted() async throws {
        let file = try file(withLines: """
        func f(_ a: Int, _ b: Int) -> Bool {
            #if os(iOS)
            // muter:disable
            return a < b
            // muter:enable
            #else
            return a > b
            #endif
        }
        """)
        state.sourceFileCandidates = [file]
        state.buildConditions = macOSBuild

        let result = try await sut.run(with: state)

        XCTAssertEqual(try mutantLines(in: result), [7])
        XCTAssertFalse(result.contains { change in
            if case .mutantsDropped = change { return true }
            return false
        })
    }

    // A mutant of code the build leaves out can't conflict with one of code it compiles.
    func test_aMutantInAnInactiveIf_doesntPruneAnActiveOne() async throws {
        let file = try file(withLines: """
        func f(_ a: Int, _ b: Int) -> some Equatable {
            #if os(iOS)
            if a > b { return a < b }
            #endif
            return a > b
        }
        """)
        state.sourceFileCandidates = [file]
        state.buildConditions = macOSBuild

        let result = try await sut.run(with: state)

        XCTAssertEqual(try mutantLines(in: result), [5])
        XCTAssertEqual(Set(try droppedMutants(in: result).map(\.reason)), [.inInactiveIfConfig])
    }

    func test_aFilesConditions_decideItsIfs() async throws {
        let file = try file(withLines: """
        func f(_ a: Int, _ b: Int) -> Bool {
            #if ONLY_THIS_TARGET
            return a < b
            #else
            return a > b
            #endif
        }
        """)
        state.sourceFileCandidates = [file]
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: file).deletingLastPathComponent()
        state.buildConditions = ProjectBuildConditions(
            everyTarget: BuildConditions(platform: nil, customConditions: [["ONLY_THIS_TARGET"], []]),
            customConditionsOfFile: [URL(fileURLWithPath: file).lastPathComponent: [["ONLY_THIS_TARGET"]]]
        )

        let result = try await sut.run(with: state)

        XCTAssertEqual(try mutantLines(in: result), [3])
    }

    private var macOSBuild: ProjectBuildConditions {
        ProjectBuildConditions(everyTarget: BuildConditions(
            platform: .init(system: "macOS", architectures: ["arm64"]),
            customConditions: [["DEBUG"]]
        ))
    }

    /// Mutants on lines 3 and 7, active on macOS, and on line 5, which isn't.
    private let ifsAroundMutants = """
    func f(_ a: Int, _ b: Int) -> Bool {
        #if os(macOS)
        let first = a > b
        #else
        let first = a < b
        #endif
        return first && a >= b
    }
    """

    private func file(withLines contents: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ifs-\(UUID().uuidString).swift")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    private func mutantLines(in changes: [MutationTestState.Change]) throws -> [Int] {
        let mappings = try XCTUnwrap(changes.lazy.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first)
        return Set(mappings.flatMap(\.mutationSchemata).map(\.position.line)).sorted()
    }

    private func droppedMutants(in changes: [MutationTestState.Change]) throws -> [DroppedMutant] {
        try XCTUnwrap(changes.lazy.compactMap { change -> [DroppedMutant]? in
            guard case let .mutantsDropped(dropped) = change else { return nil }
            return dropped
        }.first)
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
        // `count == 1`'s two constants, which a reference without a column names both of.
        XCTAssertEqual(mappings.flatMap(\.mutationSchemata).map(\.mutationOperatorId), [.ror, .ror])
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

    // RelationalOperatorReplacement's constants stand for the negation of a lone comparison, so it isn't made too, and
    // only while that operator is on.
    func test_aLoneComparison_isNegatedOnlyWithoutRelationalOperatorReplacement() async throws {
        for (code, ror) in [
            ("func f(a: Int, b: Int) { if a == b { print(a) } }\n", [MutationOperator.Id.ror, .ror]),
            ("func f(a: Int, b: Int) { if a < b { print(a) } }\n", [.ror, .ror]),
        ] {
            let withAll = try await operators(discoveredIn: code, by: .allOperators)
            XCTAssertEqual(withAll.filter { $0 != .relationalBoundary }, ror, code)
            let alone = try await operators(discoveredIn: code, by: [.negateConditional])
            XCTAssertEqual(alone, [.negateConditional], code)
            let besideOthers = try await operators(discoveredIn: code, by: [.negateConditional, .logicalOperator])
            XCTAssertEqual(besideOthers, [.negateConditional], code)
        }
    }

    // RelationalOperatorReplacement's constants replace a comparison that is a value too, so ReplaceBooleanValue leaves
    // it to them while that operator is on.
    func test_aComparisonThatIsAValue_isReplacedByReplaceBooleanValueOnlyWithoutRelationalOperatorReplacement()
        async throws {
        let code = "func f(a: Int, b: Int) -> Bool { return a < b }\n"

        let withAll = try await operators(discoveredIn: code, by: .allOperators)
        XCTAssertEqual(withAll.sorted { $0.rawValue < $1.rawValue }, [.relationalBoundary, .ror, .ror])
        let alone = try await operators(discoveredIn: code, by: [.replaceBooleanValue])
        XCTAssertEqual(alone, [.replaceBooleanValue, .replaceBooleanValue])
        let besideOthers = try await operators(discoveredIn: code, by: [.replaceBooleanValue, .relationalBoundary])
        XCTAssertEqual(besideOthers.sorted { $0.rawValue < $1.rawValue }, [
            .relationalBoundary, .replaceBooleanValue, .replaceBooleanValue,
        ])
        let other = try await operators(discoveredIn: "func f(a: Bool) -> Bool { return !a }\n", by: .allOperators)
        XCTAssertEqual(other, [.replaceBooleanValue, .replaceBooleanValue])
    }

    /// The operators of the mutants discovery finds in `code` with `list`, in the order of the file.
    private func operators(discoveredIn code: String, by list: MutationOperatorList) async throws
        -> [MutationOperator.Id] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        try code.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        state.sourceFileCandidates = [file.path]
        state.mutationOperatorList = list
        state.apply(try await sut.run(with: state))
        return state.mutationMapping.flatMap(\.mutationSchemata).map(\.mutationOperatorId)
    }

    // `--mutant` discovers every operator, and must still find the mutant a run with NegateConditional alone reported.
    func test_aMutantNamed_findsTheNegationOfALoneComparison() async throws {
        for (code, column) in [
            ("func f(a: Int, b: Int) { if a == b { print(a) } }\n", 29),
            ("func f(a: Int, b: Int) { if a < b { print(a) } }\n", 29),
        ] {
            let mutants = try await mutants(named: "1:\(column) NegateConditional", in: code)
            XCTAssertEqual(mutants.map(\.mutationOperatorId), [.negateConditional], code)
            XCTAssertEqual(mutants.map(\.position.line), [1], code)
            XCTAssertEqual(mutants.map(\.position.column), [column], code)
        }
    }

    // `--mutant` must still find each mutant a run with ReplaceBooleanValue alone reported.
    func test_aMutantNamed_findsTheReplacedBoolOfAComparison() async throws {
        let code = "func f(a: Int, b: Int) -> Bool { return a < b }\n"
        for (column, after) in [(41, "true"), (46, "false")] {
            let mutants = try await mutants(named: "1:\(column) ReplaceBooleanValue", in: code)
            XCTAssertEqual(mutants.map(\.mutationOperatorId), [.replaceBooleanValue])
            XCTAssertEqual(mutants.map(\.position.column), [column])
            XCTAssertEqual(mutants.map(\.snapshot.after), [after])
        }
    }

    /// The mutants a run of all the operators with `--mutant` selects in `code`, given its mutant as `line:column
    /// Operator`.
    private func mutants(named reference: String, in code: String) async throws -> [MutationSchema] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).swift")
        try code.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        state.sourceFileCandidates = [file.path]
        state.mutationOperatorList = .allOperators
        state.runOptions = .make(mutant: try MutantReference.parse("\(file.lastPathComponent):\(reference)"))
        state.projectDirectoryURL = file.deletingLastPathComponent()
        state.mutatedProjectDirectoryURL = file.deletingLastPathComponent()

        state.apply(try await sut.run(with: state))
        state.apply(try await SelectMutant().run(with: state))

        return state.mutationMapping.flatMap(\.mutationSchemata)
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

    // The two copies have mutants at one place, RelationalOperatorReplacement's swap and RelationalBoundary's, beside
    // the former's constant, which ReplaceBooleanValue leaves the value to. Their switch IDs named the file alone, so
    // testing either copy's mutant switched on the other copy's too.
    func test_givesFilesWithTheSameNameSwitchIDsOfTheirOwn() async throws {
        let paths = try makeSourceFiles(at: ["First/Module.swift", "Second/Module.swift"])
        state.sourceFileCandidates = paths

        let result = try await sut.run(with: state)
        let change = try XCTUnwrap(result.first)

        guard case let .mutationMappingsDiscovered(mappings) = change else {
            return XCTFail("Expected mappings, got \(change)")
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
