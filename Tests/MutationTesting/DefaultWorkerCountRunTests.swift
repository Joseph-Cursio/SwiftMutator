@testable import muterCore
import XCTest

/// A SwiftPM run that neither `mutationTestWorkers` nor `--workers` gives a count.
final class DefaultWorkerCountRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var clonedCounts: [Int] = []
    private var removedClones: [[URL]] = []
    private var choices: [WorkerChoice] = []

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [unowned self] _, count in
            clonedCounts.append(count)
            return Array(repeating: workerClone, count: count)
        },
        removeWorkerDirectories: { [unowned self] in removedClones.append($0) }
    )

    // After `setUpWithError`, as XCTest calls them, as the world is made anew in each.
    override func setUp() {
        super.setUp()

        current.processorCount = 18
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.loggingDirectory = "/logs"
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        whenSent(.workersChosen) { [unowned self] event in
            if case let .workersChosen(choice) = event { choices.append(choice) }
        }
    }

    private func testing(_ mutants: Int) throws {
        state.mutationMapping = try (1...mutants).map { try makeSchemataMapping(line: $0) }
    }

    func test_aLargeRun_testsOnTheMostDefaultWorkers_eachInItsOwnClone() async throws {
        try testing(200)
        ioDelegate.testSuiteOutcomes = Array(repeating: .passed, count: 4) + Array(repeating: .failed, count: 200)

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [3])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 4)
        XCTAssertNil(header.configuration.mutationTestWorkers, "the configuration is kept as loaded")
        XCTAssertEqual(choices.map(\.used), [4])
        XCTAssertEqual(choices.map(\.isDefaultCount), [true])
    }

    // A clone costs about a baseline build, which a few mutants don't pay back.
    func test_aSmallRun_makesNoClone_andSaysNothing() async throws {
        try testing(49)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 49)

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(choices.map(\.sentence), [nil])
    }

    func test_aMachineOfFewProcessors_makesNoClone() async throws {
        current.processorCount = 3
        try testing(200)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 200)

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(choices.map(\.sentence), [nil])
    }

    // A suite that can't run beside a copy of itself worked before the default changed, and still does.
    func test_aCloneWhoseBaselineFails_dropsTheRunToOneWorker_withANotice() async throws {
        try testing(60)
        // The baseline, the clone's, then each mutant, one at a time in the mutated project.
        ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .failed, count: 60)
        timeTheTestRun(seconds: 12)

        let result = try await sut.run(with: state)

        XCTAssertEqual(removedClones, [[workerClone]], "removed at once, and not again at the end")
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [workerClone])
        XCTAssertEqual(
            Set(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }),
            ["runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)"]
        )
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else {
            return XCTFail("Expected an outcome, got \(result)")
        }
        XCTAssertEqual(outcome.mutations.count, 60)
        // The record is the one worker's, with one worker's time limit.
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 1)
        XCTAssertEqual(header.timeoutSeconds, 60)

        XCTAssertEqual(choices.map(\.used), [2, 1])
        XCTAssertEqual(
            choices.last?.sentence,
            "👷 Testing one mutant at a time instead: worker 1's copy of the project didn't pass the baseline the "
                + "first one passed (its log is baseline run worker 1.log), so your tests may not run beside a copy "
                + "of themselves, or the builds ran out of disk space or memory. `mutationTestWorkers: 1` skips trying."
        )
        XCTAssertTrue(fileManager.paths.contains("/logs/baseline run worker 1.log"), "\(fileManager.paths)")
    }

    func test_aCloneThatCanNotBeCopied_dropsTheRunToOneWorker_withANotice() async throws {
        try testing(60)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 60)
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, _ in
                throw PerformMutationTesting.WorkerDirectoryError(
                    clone: workerClone, status: 1, error: "No space left on device"
                )
            },
            removeWorkerDirectories: { [unowned self] in removedClones.append($0) }
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(removedClones, [], "a copy that fails removes what it made")
        XCTAssertEqual(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).workers, 1)
        XCTAssertEqual(
            choices.last?.sentence,
            "👷 Testing one mutant at a time instead: SwiftMutator could not clone the mutated project to "
                + "/project_mutated_worker1 for a parallel worker (cp exited 1): No space left on device. "
                + "`mutationTestWorkers: 1` skips trying."
        )
    }

    // Stopping the run kills the clones' builds, which then fail. That's a stop, not a reason to go on with one worker.
    func test_aStopWhileTheClonesBuild_stopsTheRun() async throws {
        try testing(60)
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 1 { mutationTesting.cancel() }
        }

        let result = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertEqual(choices.map(\.used), [2])
    }

    // A count that was asked for keeps its meaning: the run stops, rather than test on fewer than that.
    func test_aCountThatWasAskedFor_stillStopsTheRun() async throws {
        state.muterConfiguration = state.muterConfiguration.overriding(workers: 2, timeout: nil)
        try testing(60)
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: workerClone.path, log: "testLog")
            )
        )
    }

    // The default is SwiftPM's alone: each xcodebuild worker takes a simulator.
    func test_anXcodebuildProject_stillTestsOneAtATime() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )
        try testing(200)
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 200)

        _ = try await sut.run(with: state)

        XCTAssertEqual(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).workers, 1)
        XCTAssertEqual(clonedCounts, [])
    }

    private func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The clock moves by `seconds` during the timed test run.
    private func timeTheTestRun(seconds: UInt64) {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += seconds * 1_000_000_000 } }
    }

    private func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line, line: line, column: 0),
                        snapshot: .null
                    ),
                ]
            )
        )
    }
}
