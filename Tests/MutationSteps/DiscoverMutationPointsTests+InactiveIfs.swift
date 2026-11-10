@testable import muterCore
import SwiftSyntax
import XCTest

extension DiscoverMutationPointsTests {
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

    var macOSBuild: ProjectBuildConditions {
        ProjectBuildConditions(everyTarget: BuildConditions(
            platform: .init(system: "macOS", architectures: ["arm64"]),
            customConditions: [["DEBUG"]]
        ))
    }

    func file(withLines contents: String) throws -> String {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ifs-\(UUID().uuidString).swift")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }

    func mutantLines(in changes: [MutationTestState.Change]) throws -> [Int] {
        let mappings = try XCTUnwrap(changes.lazy.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first)
        return Set(mappings.flatMap(\.mutationSchemata).map(\.position.line)).sorted()
    }

    func droppedMutants(in changes: [MutationTestState.Change]) throws -> [DroppedMutant] {
        try XCTUnwrap(changes.lazy.compactMap { change -> [DroppedMutant]? in
            guard case let .mutantsDropped(dropped) = change else { return nil }
            return dropped
        }.first)
    }

    /// A file with a mutant that has no place for a switch, on line 3, and one that does, on line 4.
    func droppingFile() throws -> String {
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
}
