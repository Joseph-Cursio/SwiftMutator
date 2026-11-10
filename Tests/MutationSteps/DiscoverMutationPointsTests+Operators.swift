@testable import muterCore
import SwiftSyntax
import XCTest

private final class PreparationCount: @unchecked Sendable { // `stored` is behind `lock`
    private let lock = NSLock()
    private var stored = 0

    var count: Int { lock.withLock { stored } }

    func add() {
        lock.withLock { stored += 1 }
    }
}

extension DiscoverMutationPointsTests {
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
            XCTFail("Expected mappings, got \(result)")
            return
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
            XCTFail("Expected mappings, got \(result)")
            return
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
    func operators(discoveredIn code: String, by list: MutationOperatorList) async throws
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
    func mutants(named reference: String, in code: String) async throws -> [MutationSchema] {
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
    func opaqueBodyFile() throws -> String {
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
}
