import Foundation
@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

final class LoadMuterTestPlanTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = LoadMuterTestPlan()
    private let testPlanPath = "/path/to/project/muter-mappings.json"
    private let project = URL(fileURLWithPath: "/path/to/project")

    func test_whenThereIsNotTestPlanUrl_thenThrowError() async throws {
        state.runOptions = .make(testPlanURL: nil)

        try await assertThrowsMuterError(
            sut.run(with: state),
            .literal(reason: "Could not load the test plan")
        )
    }

    func test_whenCannotLoadTestPlan_thenThrowError() async throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))

        try await assertThrowsMuterError(
            sut.run(with: state),
            .literal(reason: "Could not load the test plan at path: \(testPlanPath)")
        )
    }

    func test_loadMuterTestPlan() throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        let plan = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/project_mutated",
            projectCoverage: 23
        )
        let data = plan.toData(under: project)
        fileManager.fileContentsToReturn = data

        let result = try sut.run(with: state)

        XCTAssertEqual(
            result, [
                .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/project_mutated")),
                .projectCoverage(.init(percent: 23)),
                .mutationMappingsDiscovered([]),
                .testPlanLoaded(
                    LoadedTestPlan(
                        path: testPlanPath,
                        sha256: FileDigest.sha256(of: data),
                        formatVersion: TestPlanCoding.formatVersion,
                        swiftMutatorVersion: muterCore.version,
                        scope: TestPlanScope(operators: .allOperators, filesToMutate: []),
                        sources: nil,
                        mutatedFiles: nil,
                        linkedFiles: nil,
                        mutatedPaths: []
                    )
                ),
            ]
        )
    }

    // The plan names its copy as ../project_mutated and each mutant's file relative to the copy. A run resolves them
    // to the paths a plan from before format versions recorded, with no `..` left in the copy's.
    func test_aRelativePlan_resolvesToTheAbsolutePathsItWasMadeWith() throws {
        let plan = MuterTestPlan.make(mutatedProjectPath: "/path/to/project_mutated", mappings: [try mapping()])
        let written = plan.toData(under: project)
        XCTAssertTrue(String(lossyUTF8: written).contains("\"mutatedProject\" : \"../project_mutated\""))
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        fileManager.fileContentsToReturn = written
        fileManager.fileContentsToReturn = plan.legacyData

        let relative = try sut.run(with: state)
        let absolute = try sut.run(with: state)

        XCTAssertEqual(relative.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/project_mutated")))
        XCTAssertEqual(mappings(in: relative), mappings(in: absolute))
        let schemata = try XCTUnwrap(mappings(in: relative).first).mutationSchemata
        XCTAssertFalse(schemata.isEmpty)
        XCTAssertEqual(
            schemata.map(\.filePath),
            Array(repeating: "/path/to/project_mutated/Sources/Check.swift", count: schemata.count)
        )
        XCTAssertEqual(schemata.map(\.id), plan.mappings.first?.mutationSchemata.map(\.id))
    }

    // A plan made by a SwiftMutator from before format versions: absolute paths, and -1 for coverage not gathered.
    func test_aPlanInFormat0_loadsAsBefore() throws {
        let plan = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/project_mutated",
            projectCoverage: -1,
            mappings: [try mapping()]
        )
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = URL(fileURLWithPath: "/somewhere/else")
        fileManager.fileContentsToReturn = plan.legacyData

        let result = try sut.run(with: state)

        XCTAssertEqual(result.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/project_mutated")))
        XCTAssertEqual(result[safe: 1], .projectCoverage(.null))
        XCTAssertEqual(
            mappings(in: result).first?.mutationSchemata.map(\.filePath).first,
            "/path/to/project_mutated/Sources/Check.swift"
        )
        guard case let .testPlanLoaded(loaded) = result.last else {
            XCTFail("The plan isn't recorded: \(result)")
            return
        }
        XCTAssertEqual(loaded.formatVersion, 0)
        XCTAssertNil(loaded.swiftMutatorVersion)
        XCTAssertNil(loaded.sources)
        XCTAssertNil(loaded.mutatedFiles)
    }

    // `CheckTestPlanSources` checks the project against them, and `FingerprintProjectTree` the copy's mutated files
    // against what the plan left there.
    func test_theProjectsFilesThePlanWasMadeFrom_andItsMutatedFiles_reachTheState() throws {
        let files = ["Sources/Check.swift": "abc"]
        let sources = ProjectTree(
            listedBy: .git,
            files: files,
            excluded: ["muter.conf.yml"],
            treeSHA256: ProjectTree.treeHash(of: files)
        )
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        let mutatedFiles = ["Sources/Check.swift": "def"]
        fileManager.fileContentsToReturn = MuterTestPlan.make(sources: sources, mutatedFiles: mutatedFiles)
            .toData(under: project)

        state.apply(try sut.run(with: state))

        XCTAssertEqual(state.testPlan?.sources, sources)
        XCTAssertEqual(state.testPlan?.mutatedFiles, mutatedFiles)
    }

    // `--mutant` narrows the run's mappings, not the plan's files, which `CheckTestPlanSources` tells the project by. A
    // file outside the copy isn't the project's.
    func test_theFilesThePlanMutates_andItsLinkedFiles_reachTheState() throws {
        let outside = SchemataMutationMapping(filePath: "/elsewhere/Outside.swift")
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        let plan = MuterTestPlan.make(
            linkedFiles: ["Sources/Check.swift": "abc"],
            mappings: [try mapping(), outside]
        )
        fileManager.fileContentsToReturn = plan.toData(under: project)

        state.apply(try sut.run(with: state))

        XCTAssertEqual(state.testPlan?.mutatedPaths, ["Sources/Check.swift"])
        XCTAssertEqual(state.testPlan?.linkedFiles, ["Sources/Check.swift": "abc"])
    }

    // A run of the plan compares the mutants of code no test ran that it records, as a run that discovers its own
    // does; a plan that doesn't record them, as an older SwiftMutator's, leaves them unknown, as does `--mutant`,
    // whose run compares no survivors.
    func test_theMutantsOfCodeNoTestRanThePlanRecords_reachTheState() throws {
        let uncovered = UncoveredMutant(
            key: MutantKey(path: "Sources/New.swift", mutationOperatorId: .ror, line: 4, column: 9, occurrence: 0),
            snapshot: .make(before: "<", after: ">", description: "changed < to >")
        )
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        fileManager.fileContentsToReturn = MuterTestPlan.make(mutantsNotCovered: [uncovered]).toData(under: project)

        state.apply(try sut.run(with: state))
        XCTAssertEqual(state.uncoveredMutants, [uncovered])

        let older = MutationTestState()
        older.runOptions = state.runOptions
        older.projectDirectoryURL = project
        fileManager.fileContentsToReturn = MuterTestPlan.make().toData(under: project)
        older.apply(try sut.run(with: older))
        XCTAssertNil(older.uncoveredMutants)

        let lone = MutationTestState()
        lone.runOptions = .make(
            testPlanURL: URL(fileURLWithPath: testPlanPath),
            mutant: MutantReference(path: "Sources/Check.swift", line: 2, column: nil)
        )
        lone.projectDirectoryURL = project
        fileManager.fileContentsToReturn = MuterTestPlan.make(mutantsNotCovered: [uncovered]).toData(under: project)
        lone.apply(try sut.run(with: lone))
        XCTAssertNil(lone.uncoveredMutants)
    }

    func test_theLoadedPlan_isKeptInTheState() throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        let data = MuterTestPlan.make().toData(under: project)
        fileManager.fileContentsToReturn = data

        state.apply(try sut.run(with: state))

        XCTAssertEqual(state.testPlan?.path, testPlanPath)
        XCTAssertEqual(state.testPlan?.sha256, FileDigest.sha256(of: data))
        XCTAssertEqual(state.mutatedProjectDirectoryURL, URL(fileURLWithPath: "/path/to/project_mutated"))
    }

    // A plan run's results file and its resume check describe the plan's mutants, not the command's defaults.
    func test_theLoadedPlan_setsTheOperatorsAndFilesItWasChosenBy() throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.mutationOperatorList = .allOperators
        state.projectDirectoryURL = project
        let plan = MuterTestPlan.make(
            scope: TestPlanScope(operators: [.swapTernary, .logicalOperator], filesToMutate: ["Sources/Check.swift"])
        )
        fileManager.fileContentsToReturn = plan.toData(under: project)

        state.apply(try sut.run(with: state))

        XCTAssertEqual(state.mutationOperatorList, [.logicalOperator, .swapTernary])
        XCTAssertEqual(state.filesToMutate, ["Sources/Check.swift"])
        XCTAssertEqual(
            state.testPlan?.scope,
            TestPlanScope(operators: [.logicalOperator, .swapTernary], filesToMutate: ["Sources/Check.swift"])
        )
    }

    // A plan in format 0 doesn't say, and was made with every operator and file: what the run was given stays.
    func test_aPlanInFormat0_leavesTheOperatorsAndFilesAsTheRunWasGiven() throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.mutationOperatorList = .allOperators
        state.projectDirectoryURL = project
        fileManager.fileContentsToReturn = MuterTestPlan.make().legacyData

        state.apply(try sut.run(with: state))

        XCTAssertEqual(state.mutationOperatorList, .allOperators)
        XCTAssertEqual(state.filesToMutate, [])
        XCTAssertNil(state.testPlan?.scope)
    }

    // Another run of the project may be removing or rewriting the mutated project until it is locked, which comes
    // after this step: only the plan itself is read.
    func test_readsNothingInTheMutatedProject() throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: testPlanPath))
        state.projectDirectoryURL = project
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let plan = MuterTestPlan.make(
            mutatedProjectPath: "/path/to/project_mutated",
            mappings: [try mapping()]
        )
        fileManager.fileContentsToReturn = plan.toData(under: project)

        let result = try sut.run(with: state)

        XCTAssertEqual(result.first, .tempDirectoryUrlCreated(URL(fileURLWithPath: "/path/to/project_mutated")))
        XCTAssertEqual(fileManager.contentsAtPath, [testPlanPath])
    }

    private func mapping() throws -> SchemataMutationMapping {
        try XCTUnwrap(
            generateSchemataMappings(
                for: SourceCodeInfo(
                    path: "/path/to/project_mutated/Sources/Check.swift",
                    code: Parser.parse(source: "func check(_ value: Int) -> Bool {\n    return value > 1\n}\n")
                )
            ).first
        )
    }

    private func mappings(in changes: [MutationTestState.Change]) -> [SchemataMutationMapping] {
        for case let .mutationMappingsDiscovered(mappings) in changes {
            return mappings
        }
        return []
    }
}
