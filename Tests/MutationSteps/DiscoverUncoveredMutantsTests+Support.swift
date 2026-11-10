import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension DiscoverUncoveredMutantsTests {
    func write(_ contents: String, to name: String) throws -> String {
        let path = "\(project)/\(name)"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Coverage in which only `isNegative`'s body never ran, reported for the file at `path`.
    func coverageMissingIsNegative(reportedAt path: String) -> Coverage {
        Coverage.make(
            functionsCoverage: FunctionsCoverage(
                from: LLVMCoverage(data: [
                    .init(functions: [
                        Function(
                            filenames: [path],
                            regions: [.make(lineStart: 1, columnStart: 39, lineEnd: 1, columnEnd: 52)]
                        ),
                    ]),
                ])
            )
        )
    }

    func keys(of changes: [MutationTestState.Change]) throws -> [MutantKey] {
        let mappings = try XCTUnwrap(changes.lazy.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first)
        return MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: state.mutatedProjectDirectoryURL)
    }

    /// A baseline file of `survivors`, each a `<` made `<=`, by the SwiftMutator under test.
    func baselineFile(recording survivors: [MutantKey]) -> BaselineFile {
        BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: muterCore.version,
            score: .init(killed: 1, scored: 2),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: survivors.map { BaselineSurvivor(mutant: $0, outcome: .survived, before: ">", after: ">=") }
        )
    }

    /// What `body` throws; nil when it throws nothing.
    func error(_ body: () async throws -> [MutationTestState.Change]) async -> Error? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }

    /// What discovery ends the run with, when it has only mutants of code no test ran.
    func onlyUncoveredMutants(of state: MutationTestState) async throws -> OnlyUncoveredMutants {
        do {
            let changes = try await DiscoverMutationPoints().run(with: state)
            XCTFail("Discovery found mutants to test: \(changes)")
        } catch let only as OnlyUncoveredMutants {
            return only
        }
        throw MuterError.noMutationPointsDiscovered
    }

    func uncoveredMutants(in changes: [MutationTestState.Change]) -> [UncoveredMutant] {
        changes.lazy.compactMap { change -> [UncoveredMutant]? in
            guard case let .mutantsNotCovered(mutants) = change else { return nil }
            return mutants
        }.first ?? []
    }

    func unselectedMutants(in changes: [MutationTestState.Change]) -> [UnselectedMutant] {
        changes.lazy.compactMap { change -> [UnselectedMutant]? in
            guard case let .mutantsNotSelected(mutants) = change else { return nil }
            return mutants
        }.first ?? []
    }
}
