@testable import muterCore
import TestingExtensions
import XCTest

/// What mutation testing writes to the run's results file as it goes.
final class PerformMutationTestingResultsTests: MuterTestCase {
    let state = MutationTestState()
    let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    let killingLog = """
    ◇ Test run started.
    ✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4
    ✘ Test sum() failed after 0.001 seconds with 1 issue.
    ✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue.
    """

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationMapping = try [
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
            makeSchemataMapping(file: "Sources/Product.swift", line: 7),
        ]
    }

    func test_theHeaderIsWrittenOnceTheBaselinePasses_withEffectiveTimeoutWorkersAndCounts() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let probed = Locked<[MuterConfiguration]>([])
        current.provenance = { configuration in
            probed.change { $0.append(configuration) }
            return .fixture
        }
        var linesAtTheBaselinesLog: [String]?
        whenSent(.newTestLogAvailable) { event in
            if (event.object as? MutationTestLog)?.mutationPoint == nil {
                linesAtTheBaselinesLog = self.resultsFiles.lines
            }
        }
        let sent = recordEvents(named: [.resultsFileCreated, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, ["/logs"])
        let headers = try resultsFiles.records(ResultsHeader.self)
        XCTAssertEqual(headers.count, 1)
        let header = try XCTUnwrap(headers.first)
        XCTAssertEqual(try resultsFiles.kinds().first, "header")
        XCTAssertEqual(header.session, 1)
        XCTAssertEqual(header.startedAt, current.now())
        XCTAssertEqual(header.provenance, .fixture)
        XCTAssertEqual(probed.value, [state.muterConfiguration], "the configuration as loaded is probed, once")
        XCTAssertEqual(header.configuration, state.muterConfiguration)
        XCTAssertEqual(header.logDirectory, "/logs")
        XCTAssertEqual(header.mutatedProjectPath, "/project_mutated")
        // The spy's timed test run returns at once, so the minimum default applies.
        XCTAssertEqual(header.testRunSeconds, 0)
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumTestRunTimeout)
        XCTAssertTrue(header.timeoutIsDefault)
        XCTAssertEqual(header.workers, 1)
        XCTAssertTrue(header.failedTestLinesAreReliable)
        XCTAssertEqual(header.mutantsDiscovered, 2)
        XCTAssertEqual(header.mutantsToTest, 2)
        // Before the baseline's log, which starts the progress bar, so the file's path is printed first.
        XCTAssertEqual(linesAtTheBaselinesLog?.count, 1)
        XCTAssertEqual(sent().prefix(2).map(\.name), [.resultsFileCreated, .newTestLogAvailable])
        XCTAssertEqual(sent().first?.object as? String, "/logs/results.jsonl")
        XCTAssertNil(fileManager.createdFiles["/logs/\(ResultsFile.noteFileName)"], "a first session leaves no note")
    }

    func test_theHeaderRecordsTheProjectTree() async throws {
        let tree = makeProjectTree(["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "77e0", "README.md": "0b9d"])
        state.projectTree = tree
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.project), [tree])
    }

    // A state whose project wasn't fingerprinted has no tree, and neither does its header.
    func test_aStateWithoutAProjectTree_writesAHeaderWithoutOne_andMutantLinesWithoutHashes() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.project), [nil])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.fileSHA256), [nil, nil])
    }

    // The reports say where the results came from, as the header says, and each mutant's key and duration, as its line
    // records them: to the millisecond, so that `report` of the file gives the same.
    func test_theOutcome_namesTheResultsFile_andEachMutantsKeyAndDuration() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let ticks = Locked<UInt64>(0)
        current.instant = {
            ticks.change { count in
                count += 1
                return DispatchTime(uptimeNanoseconds: count * 1_234_567_891)
            }
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(outcome.run, RunDetails(of: [("/logs/results.jsonl", [header])]))
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(outcome.mutations.compactMap(\.key), records.map(\.key))
        XCTAssertEqual(outcome.mutations.compactMap(\.durationSeconds), records.map(\.durationSeconds))
        XCTAssertEqual(outcome.mutations.map(\.durationSeconds), [1.235, 1.235])
    }

    // A test plan's run records the plan it tested, and the plan's copy as it was tested, which each mutant's line
    // gives its file's hash from: the code its verdict came from, with any fix made by hand.
    func test_aTestPlansRun_recordsThePlan_andTheCopysHashes() async throws {
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        let plan = LoadedTestPlan(
            path: "/project/muter-mappings.json",
            sha256: "9e1f",
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: muterCore.version,
            scope: nil,
            sources: nil,
            mutatedFiles: ["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "0000"],
            linkedFiles: nil,
            mutatedPaths: []
        )
        let copy = makeProjectTree(["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "77e0"])
        state.apply([.testPlanLoaded(plan), .projectTreeFingerprinted(copy)])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(try resultsFiles.records(ResultsHeader.self).first)
        XCTAssertTrue(header.usingTestPlan)
        XCTAssertEqual(header.testPlan, TestPlanRecord(plan))
        XCTAssertEqual(header.project, copy)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.fileSHA256), ["5a1c", "77e0"])
    }

    // The reports check a mutant's original file against its hash before showing its line: the project's, which a
    // test plan's run records only as the plan does, as its own tree is the rewritten copy's.
    func test_theHashesTheReportsCheck_areTheProjects_evenForATestPlansRun() {
        let tree = makeProjectTree(["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "77e0"])
        state.apply([.projectTreeFingerprinted(tree)])
        XCTAssertEqual(PerformMutationTesting.sourceDigests(of: state), tree.files)

        let plan = { (sources: ProjectTree?, linkedFiles: [String: String]?) in
            LoadedTestPlan(
                path: "/project/muter-mappings.json",
                sha256: "9e1f",
                formatVersion: TestPlanCoding.formatVersion,
                swiftMutatorVersion: muterCore.version,
                scope: nil,
                sources: sources,
                mutatedFiles: nil,
                linkedFiles: linkedFiles,
                mutatedPaths: []
            )
        }
        let project = makeProjectTree(["Sources/Sum.swift": "0b1d", "Sources/Link.swift": "link:9a9a"])
        state.apply([.testPlanLoaded(plan(project, ["Sources/Link.swift": "4e4e"]))])
        XCTAssertEqual(
            PerformMutationTesting.sourceDigests(of: state),
            ["Sources/Sum.swift": "0b1d", "Sources/Link.swift": "4e4e"]
        )

        state.apply([.testPlanLoaded(plan(nil, nil))])
        XCTAssertNil(PerformMutationTesting.sourceDigests(of: state), "a plan in format 0 records nothing")
    }

    // No more workers run than there are mutants, and the header says how many ran.
    func test_theHeadersWorkers_areTheEffectiveCount_whenMoreAreConfiguredThanThereAreMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4
        )
        // The baseline, the one worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 2)
        XCTAssertEqual(header.configuration.mutationTestWorkers, 4, "the configuration is kept as loaded")
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [workerClone])
    }

    func test_noResultsFileWhenTheBaselineFails() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(ioDelegate.methodCalls, ["benchmarkTests(using:savingResultsIntoFileNamed:)"], "no timed run")
    }
}
