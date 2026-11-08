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
            mutatedFiles: [:],
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

    // The project's files as they were before anything was rewritten, which a run of the plan checks the project
    // against, and each mutated file as the copy holds it once its switches are in.
    func test_recordsTheProjectsFiles_andHashesTheMutatedFilesInTheCopy() async throws {
        let state = makeState()
        let files = ["Sources/Check.swift": "original", "Tests/CheckTests.swift": "tests"]
        state.projectTree = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        let rewritten = Data("func check(_ value: Int) -> Bool { /* switches */ }".utf8)
        fileManager.fileContentsToReturn = rewritten

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertEqual(file.sources, state.projectTree)
        XCTAssertEqual(file.mutatedFiles, ["Sources/Check.swift": FileDigest.sha256(of: rewritten)])
        XCTAssertEqual(fileManager.contentsAtPath, ["/path/to/project_mutated/Sources/Check.swift"])
        XCTAssertNil(file.linkedFiles)
    }

    // The project's files record a symbolic link only by where it points, so a file with mutants that is one is also
    // recorded by what the link's file holds, read in the project, never the copy, whose file the switches replaced.
    func test_aFileWithMutantsThatIsALink_isRecordedByWhatItsFileHolds() async throws {
        let root = try makeTemporaryDirectory()
        let state = makeState()
        state.projectDirectoryURL = URL(fileURLWithPath: "\(root)/project")
        try FileManager.default.createDirectory(atPath: "\(root)/project/Sources", withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: URL(fileURLWithPath: "\(root)/Check.swift"))
        try FileManager.default.createSymbolicLink(
            atPath: "\(root)/project/Sources/Check.swift",
            withDestinationPath: "../../Check.swift"
        )
        let link = ProjectTree.linkPrefix + FileDigest.sha256(of: Data("../../Check.swift".utf8))
        let files = ["Sources/Check.swift": link]
        state.projectTree = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: [],
            treeSHA256: ProjectTree.treeHash(of: files)
        )

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertEqual(file.linkedFiles, ["Sources/Check.swift": FileDigest.sha256(of: Data("shared".utf8))])
    }

    func test_coverageThatWasntGathered_isLeftOut() async throws {
        let state = makeState()
        state.projectCoverage = .null

        _ = try await sut.run(with: state)

        let file = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertNil(file.projectCoverage)
    }

    // A run of the plan compares them with `--baseline`'s file, and records them, as a run that discovers its own
    // mutants does; none is recorded as none. A plan made without them leaves the key out.
    func test_recordsTheMutantsOfCodeNoTestRan() async throws {
        let state = makeState()
        let uncovered = UncoveredMutant(
            key: MutantKey(path: "Sources/New.swift", mutationOperatorId: .ror, line: 4, column: 9, occurrence: 0),
            snapshot: .make(before: "<", after: ">", description: "changed < to >")
        )
        state.apply([.mutantsNotCovered([uncovered])])

        _ = try await sut.run(with: state)

        let written = try XCTUnwrap(writeFile.contentPassed)
        XCTAssertTrue(written.contains(#""path" : "Sources/New.swift""#), written)
        let plan = try TestPlanCoding.read(Data(written.utf8), path: "/plan.json", under: state.projectDirectoryURL)
        XCTAssertEqual(plan.mutantsNotCovered, [uncovered])

        state.apply([.mutantsNotCovered([])])
        _ = try await sut.run(with: state)
        let none = try JSONDecoder().decode(TestPlanFile.self, from: Data(try XCTUnwrap(writeFile.contentPassed).utf8))
        XCTAssertEqual(none.mutantsNotCovered, [])

        _ = try await sut.run(with: makeState())
        XCTAssertFalse(try XCTUnwrap(writeFile.contentPassed).contains("mutantsNotCovered"))
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
