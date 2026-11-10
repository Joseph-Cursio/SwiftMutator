@testable import muterCore
import XCTest

extension ResultsRecordTests {
    func test_aHeaderFromARunsState_keepsTheConfigurationAsLoaded_andTheEffectiveSettingsBesideIt() {
        let loaded = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 4,
            stopAtFirstFailure: true
        )
        let project = makeProjectTree()
        let state = stateOfARun(thatLoaded: loaded, fingerprinting: project)
        let effective = loaded.withUnreliableFailedTestLines().withDefaultTestSuiteTimeout(86)

        let header = ResultsHeader(
            session: 1,
            startedAt: startedAt,
            state: state,
            logDirectory: "/project_muter_logs/run",
            configuration: effective,
            baselineSeconds: 32.125,
            workers: 4,
            mutantsDiscovered: 7,
            mutantsToTest: 7,
            provenance: .fixture,
            testRunSeconds: 10.75
        )

        XCTAssertEqual(header, headerOfARun(thatLoaded: loaded, fingerprinting: project))
        XCTAssertEqual(header.kind, "header")
    }

    /// The state of a run of two operators on `Sum.swift`, with the project's coverage and a newer version found,
    /// that loaded `configuration` and fingerprinted `project`.
    private func stateOfARun(
        thatLoaded configuration: MuterConfiguration,
        fingerprinting project: ProjectTree
    ) -> MutationTestState {
        let state = MutationTestState(
            from: .make(
                filesToMutate: ["Sum.swift"],
                mutationOperatorsList: [.ror, .logicalOperator],
                skipCoverage: true
            )
        )
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = mutatedRoot
        state.newVersion = "9.9.9"
        state.projectCoverage = .make(percent: 87, filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"])
        state.muterConfiguration = configuration
        state.projectTree = project
        return state
    }

    /// The header the session of `stateOfARun(thatLoaded:fingerprinting:)` writes: the configuration as loaded, the
    /// effective settings beside it.
    private func headerOfARun(
        thatLoaded configuration: MuterConfiguration,
        fingerprinting project: ProjectTree
    ) -> ResultsHeader {
        ResultsHeader(
            // Its kills may keep no log, as `keepAllLogs` isn't set.
            formatVersion: ResultsCoding.omittedLogsFormatVersion,
            session: 1,
            startedAt: startedAt,
            provenance: .fixture,
            configuration: configuration,
            operators: ["ChangeLogicalConnector", "RelationalOperatorReplacement"],
            filesToMutate: ["Sum.swift"],
            skipCoverage: true,
            usingTestPlan: false,
            projectPath: "/project",
            mutatedProjectPath: "/project_mutated",
            logDirectory: "/project_muter_logs/run",
            coverage: CoverageSummary(
                percent: 87,
                filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"]
            ),
            newVersion: "9.9.9",
            baselineSeconds: 32.125,
            testRunSeconds: 10.75,
            timeoutSeconds: 86,
            timeoutIsDefault: true,
            workers: 4,
            stopsAtFirstFailure: false,
            failedTestLinesAreReliable: false,
            mutantsDiscovered: 7,
            mutantsToTest: 7,
            project: project,
            mutantsReused: nil,
            waived: nil,
            forced: nil
        )
    }

    func test_aHeaderFromARunsState_withAConfiguredTimeLimit_aTestPlanAndNoCoverage() {
        let state = MutationTestState(from: .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json")))
        let loaded = MuterConfiguration(executable: "/usr/bin/swift", testSuiteTimeOut: 60, stopAtFirstFailure: true)
        state.muterConfiguration = loaded

        let header = ResultsHeader(
            session: 1,
            startedAt: startedAt,
            state: state,
            logDirectory: "/logs",
            configuration: loaded.withDefaultTestSuiteTimeout(96.5),
            baselineSeconds: 32.125,
            workers: 1,
            mutantsDiscovered: 3,
            mutantsToTest: 3,
            provenance: .fixture
        )

        XCTAssertEqual(header.timeoutSeconds, 60)
        XCTAssertFalse(header.timeoutIsDefault)
        XCTAssertTrue(header.usingTestPlan)
        XCTAssertNil(header.coverage)
        XCTAssertNil(header.project)
        XCTAssertTrue(header.stopsAtFirstFailure)
        XCTAssertTrue(header.failedTestLinesAreReliable)
    }

    // run-without-mutating takes neither option: the plan's mutants were chosen by what mutate-without-running was
    // given, which the plan records.
    func test_aHeaderFromATestPlanRun_recordsTheOperatorsAndFilesThePlanWasChosenBy() {
        let state = MutationTestState(from: .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json")))
        state.apply([
            .testPlanLoaded(
                LoadedTestPlan(
                    path: "/project/muter-mappings.json",
                    sha256: "abc",
                    formatVersion: TestPlanCoding.formatVersion,
                    swiftMutatorVersion: muterCore.version,
                    scope: TestPlanScope(operators: [.swapTernary, .ror], filesToMutate: ["Sources/Sum.swift"]),
                    sources: nil,
                    mutatedFiles: nil,
                    linkedFiles: nil,
                    mutatedPaths: []
                )
            ),
        ])

        let header = ResultsHeader(
            session: 1,
            startedAt: startedAt,
            state: state,
            logDirectory: "/logs",
            configuration: MuterConfiguration(executable: "/usr/bin/swift"),
            baselineSeconds: nil,
            workers: 1,
            mutantsDiscovered: 3,
            mutantsToTest: 3,
            provenance: .fixture
        )

        XCTAssertEqual(header.operators, ["RelationalOperatorReplacement", "SwapTernary"])
        XCTAssertEqual(header.filesToMutate, ["Sources/Sum.swift"])
        XCTAssertTrue(header.usingTestPlan)
    }

    // The plan it tested, by its path and the SHA-256 of its bytes, and the plan's copy as it was tested.
    func test_aHeaderFromATestPlanRun_recordsThePlan_andTheCopyAsTested() throws {
        let state = MutationTestState(from: .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json")))
        let files = ["Sources/Sum.swift": "5a1c"]
        let copy = ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
        state.apply([
            .testPlanLoaded(
                LoadedTestPlan(
                    path: "/project/muter-mappings.json",
                    sha256: "abc",
                    formatVersion: TestPlanCoding.formatVersion,
                    swiftMutatorVersion: "1.2.3",
                    scope: nil,
                    sources: nil,
                    mutatedFiles: ["Sources/Sum.swift": "77e0"],
                    linkedFiles: nil,
                    mutatedPaths: []
                )
            ),
            .projectTreeFingerprinted(copy),
        ])

        let header = ResultsHeader(
            session: 1,
            startedAt: startedAt,
            state: state,
            logDirectory: "/logs",
            configuration: MuterConfiguration(executable: "/usr/bin/swift"),
            baselineSeconds: nil,
            workers: 1,
            mutantsDiscovered: 1,
            mutantsToTest: 1,
            provenance: .fixture
        )

        XCTAssertEqual(
            header.testPlan,
            TestPlanRecord(
                path: "/project/muter-mappings.json",
                sha256: "abc",
                formatVersion: TestPlanCoding.formatVersion,
                swiftMutatorVersion: "1.2.3"
            )
        )
        XCTAssertEqual(header.project, copy)
        let written = try line(header)
        XCTAssertTrue(
            written.contains(
                #""testPlan":{"formatVersion":2,"path":"/project/muter-mappings.json","sha256":"abc","#
                    + #""swiftMutatorVersion":"1.2.3"}"#
            ),
            written
        )
        XCTAssertEqual(try decode(ResultsHeader.self, from: written), header)
    }

    // A plan in format 0 doesn't say which SwiftMutator made it.
    func test_aTestPlanRecord_ofAPlanInFormat0_leavesTheVersionOut() throws {
        let record = TestPlanRecord(
            path: "/project/muter-mappings.json",
            sha256: "abc",
            formatVersion: 0,
            swiftMutatorVersion: nil
        )

        XCTAssertEqual(try line(record), #"{"formatVersion":0,"path":"/project/muter-mappings.json","sha256":"abc"}"#)
    }

    // A header records it, and a resume compares it with the last header's. A run without coverage has none.
    func test_aCoverageSummary_keepsThePercentAndTheFilesWithoutCoverage_andIsNilWithoutCoverage() {
        XCTAssertEqual(
            CoverageSummary(.make(percent: 87, filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"])),
            CoverageSummary(percent: 87, filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"])
        )
        XCTAssertEqual(CoverageSummary(.make(percent: 0)), CoverageSummary(percent: 0, filesWithoutCoverage: []))
        XCTAssertNil(CoverageSummary(.null))
    }
}
