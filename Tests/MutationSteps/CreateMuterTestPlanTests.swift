import Foundation
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class CreateMuterTestPlanTests: MuterTestCase {
    private let sut = CreateMuterTestPlan()

    func test_step() async throws {
        let state = makeState()

        let expect = expectation(forEvent: .testPlanFileCreated) { event in
            XCTAssertEqual(
                event.object as? TestPlanCreated,
                TestPlanCreated(
                    path: "/path/to/project/muter-mappings.json",
                    mutatedProject: "../project_mutated",
                    mutants: state.mutationMapping.first?.mutationSchemata.count ?? -1,
                    files: 1,
                    operators: nil
                )
            )
            return true
        }

        _ = try await sut.run(with: state)

        await fulfillment(of: [expect], timeout: 2)

        XCTAssertTrue(writeFile.writeFileCalled)
        XCTAssertEqual(writeFile.pathPassed, "/path/to/project/muter-mappings.json")
    }

    func test_writesThePlanAsTestPlanCodingDoes() async throws {
        let state = makeState()

        _ = try await sut.run(with: state)

        let plan = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/project_mutated",
            projectCoverage: 47,
            scope: TestPlanScope(operators: .allOperators, filesToMutate: []),
            mappings: state.mutationMapping
        )
        XCTAssertEqual(
            writeFile.contentPassed,
            try TestPlanCoding.encode(plan, under: URL(fileURLWithPath: "/path/to/project"))
        )
    }

    // The copy is named from the project, and each mutant's file from the copy, so the two can move together. The
    // copy's code switches each mutant on by its ID, which stays as discovery made it.
    func test_writesThePathsRelativeToTheProject_andKeepsEveryID() async throws {
        let state = makeState()

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertEqual(file.formatVersion, TestPlanCoding.formatVersion)
        XCTAssertEqual(file.swiftMutatorVersion, muterCore.version)
        XCTAssertEqual(file.mutatedProject, "../project_mutated")
        XCTAssertEqual(file.projectCoverage, 47)
        XCTAssertEqual(file.mappings.map(\.filePath), ["Sources/Check.swift"])
        let schemata = try XCTUnwrap(file.mappings.first).mutationSchemata
        XCTAssertEqual(Set(schemata.map(\.filePath)), ["Sources/Check.swift"])
        XCTAssertEqual(schemata.map(\.id), state.mutationMapping.first?.mutationSchemata.map(\.id))
    }

    // What `--operators` and `--files-to-mutate` chose, which a run of the plan records as its own.
    func test_recordsTheOperatorsAndFilesTheMutantsWereChosenBy() async throws {
        let state = makeState()
        state.mutationOperatorList = [.swapTernary, .ror]
        state.filesToMutate = ["Sources/Check.swift"]

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertEqual(file.operators, ["RelationalOperatorReplacement", "SwapTernary"])
        XCTAssertEqual(file.filesToMutate, ["Sources/Check.swift"])
    }

    func test_withoutAChoice_everyOperatorAndNoFileIsRecorded() async throws {
        let state = makeState()

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertEqual(file.operators, MutationOperatorList.allOperators.map(\.rawValue).sorted())
        XCTAssertEqual(file.filesToMutate, [])
    }

    // The message names the operators only when they aren't all of them.
    func test_theCreatedPlan_namesTheOperatorsItWasChosenBy() async throws {
        let state = makeState()
        state.mutationOperatorList = [.swapTernary, .ror]
        let expect = expectation(forEvent: .testPlanFileCreated) { event in
            XCTAssertEqual(
                (event.object as? TestPlanCreated)?.operators,
                ["RelationalOperatorReplacement", "SwapTernary"]
            )
            return true
        }

        _ = try await sut.run(with: state)

        await fulfillment(of: [expect], timeout: 2)
    }

    func test_coverageThatWasntGathered_isLeftOut() async throws {
        let state = makeState()
        state.projectCoverage = .null

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertNil(file.projectCoverage)
    }

    private func makeState() -> MutationTestState {
        let state = MutationTestState()
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/path/to/project_mutated")
        state.projectDirectoryURL = URL(fileURLWithPath: "/path/to/project")
        state.projectCoverage = .make(percent: 47)
        state.mutationOperatorList = .allOperators
        state.mutationMapping = generateSchemataMappings(
            for: SourceCodeInfo(
                path: "/path/to/project_mutated/Sources/Check.swift",
                code: Parser.parse(source: "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n")
            )
        )

        return state
    }
}
