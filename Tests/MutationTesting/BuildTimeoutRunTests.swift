@testable import muterCore
import XCTest

/// `buildTimeout`'s limits on the runs ahead of the first mutant: the baseline's, a worker clone's, and the timed test
/// run's, which comes from the baseline's time.
final class BuildTimeoutRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var choices: [WorkerChoice] = []

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.loggingDirectory = "/logs"
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 1, buildTimeout: 600
        )
        state.mutationMapping = try (1...4).map(makeSchemataMapping(line:))
        let observer = runEvents.observe(.workersChosen) { [unowned self] event in
            if case let .workersChosen(choice) = event { choices.append(choice) }
        }
        addTeardownBlock { observer.cancel() }
    }

    // A baseline stopped at its limit stops the run, as a failed one does, naming the step, the limit and the log, and
    // isn't run again without a mutant: what it printed, cut short, says nothing about which don't compile.
    func test_aBaselinePastTheBuildTimeout_stopsTheRun_andIsNotRunAgain() async throws {
        state.preparedSources = ["/tmp/project/file.swift": "func bar() { }"]
        ioDelegate.testSuiteOutcomes = [.timeout, .passed]
        ioDelegate.baselineEndings = [.timedOut]
        ioDelegate.baselineTestLog = "Compiling Calc\n/tmp/project/file.swift:1:1: error: cut short\n"

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .baseline,
                seconds: 600,
                output: "Compiling Calc\n/tmp/project/file.swift:1:1: error: cut short\n",
                log: "/logs/baseline run.log"
            ))
        )
        XCTAssertEqual(ioDelegate.methodCalls, ["benchmarkTests(using:savingResultsIntoFileNamed:)"])
        XCTAssertTrue(fileManager.paths.contains("/logs/baseline run.log"), "\(fileManager.paths)")
        XCTAssertEqual(resultsFiles.directories, [])
    }

    // One that passed as it was stopped, its tests all run, ran past its limit all the same.
    func test_aBaselineThatPassedAsItWasStopped_stillStopsTheRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed]
        ioDelegate.baselineEndings = [.timedOut]

        await assertThrowsMuterError(try await sut.run(with: state)) { error in
            guard case .mutationTestingAborted(.buildTimeoutReached(.baseline, 600, _, _)) = error else {
                return XCTFail("\(error)")
            }
        }
    }

    // A count that was asked for stops the run, as a clone's failed baseline does.
    func test_aClonePastTheBuildTimeout_stopsARunWithACountAskedFor() async throws {
        state.muterConfiguration = state.muterConfiguration.overriding(workers: 2, timeout: nil)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        ioDelegate.workerBaselineEndings = [.timedOut]
        ioDelegate.workerBaselineTestLogs = ["Building for debugging...\n"]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .buildTimeoutReached(
                step: .workerBaseline(worker: 1, directory: workerClone.path),
                seconds: 600,
                output: "Building for debugging...\n",
                log: "/logs/baseline run worker 1.log"
            ))
        )
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
    }

    // With the default count, the run tests one mutant at a time instead, as after a clone's failed baseline, and says
    // why.
    func test_aClonePastTheBuildTimeout_dropsADefaultRunToOneWorker() async throws {
        current.processorCount = 18
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 600
        )
        state.mutationMapping = try (1...60).map(makeSchemataMapping(line:))
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 60)
        ioDelegate.workerBaselineEndings = [.timedOut]

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices.map(\.used), [2, 1])
        XCTAssertEqual(
            choices.last?.sentence,
            "👷 Testing one mutant at a time instead: worker 1's copy of the project didn't build and pass the "
                + "baseline within 600 s (buildTimeout), though the first one did (its log is baseline run worker "
                + "1.log), so the builds may compete for too few cores, or your tests may hang beside a copy of "
                + "themselves. `mutationTestWorkers: 1` skips trying."
        )
        XCTAssertEqual(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).workers, 1)
    }

    // The timed test run doesn't build, so it gets 5 times the baseline's time, at least a minute, and never more than
    // buildTimeout. Without a buildTimeout it has no limit, as before.
    func test_theTimedTestRun_isLimitedFromTheBaselinesTime_onlyWithABuildTimeout() async throws {
        for buildTimeout in [600, 30, nil] as [Double?] {
            state.muterConfiguration = MuterConfiguration(
                executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 1, buildTimeout: buildTimeout
            )
            ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(ioDelegate.timeLimitsWithoutBuilding, [60, 30, nil])
    }

    // The limit comes from the baseline's own time: 5 times a 100 s baseline. The baseline is timed on the monotonic
    // clock, so an hour the Mac slept through on the wall clock counts for nothing (#181).
    func test_theTimedTestRunsLimit_isFiveTimesTheBaselinesTime_onTheMonotonicClock() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 1, buildTimeout: 3_600
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let wallClock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let nanoseconds = Locked<UInt64>(1_000_000_000)
        current.now = { wallClock.value }
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningBaseline = { _ in
            wallClock.change { $0 += 3_700 }
            nanoseconds.change { $0 += 100_000_000_000 }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.timeLimitsWithoutBuilding, [500])
        XCTAssertEqual(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).baselineSeconds, 100)
    }

    // A timed test run stopped at its limit times nothing: each mutant's limit comes from the baseline, as after one
    // that failed, and the run goes on, saying so.
    func test_aTimedTestRunPastItsLimit_isSaid_andTheMutantsLimitComesFromTheBaseline() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.endingsWithoutBuildingWritingTo["timed test run"] = .timedOut
        var stopped: [RunEvent] = []
        let observer = runEvents.observe(.timedTestRunStopped) { stopped.append($0) }
        defer { observer.cancel() }

        _ = try await sut.run(with: state)

        guard case let .timedTestRunStopped(seconds, log)? = stopped.first, stopped.count == 1 else {
            return XCTFail("\(stopped)")
        }
        XCTAssertEqual(seconds, 60)
        XCTAssertEqual(log, "/logs/timed test run.log")
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertNil(header.testRunSeconds)
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumDefaultTimeout)
    }

    func test_theFollowingRunsLimit_isFiveTimesTheLongerOfTheBaselineAndACheckRun_withinItsBounds() {
        XCTAssertNil(PerformMutationTesting.followingRunLimit(buildTimeout: nil, baselineSeconds: 100))
        XCTAssertEqual(PerformMutationTesting.followingRunLimit(buildTimeout: 3_600, baselineSeconds: 100), 500)
        XCTAssertEqual(PerformMutationTesting.followingRunLimit(buildTimeout: 3_600, baselineSeconds: 2), 60)
        XCTAssertEqual(PerformMutationTesting.followingRunLimit(buildTimeout: 300, baselineSeconds: 100), 300)
        XCTAssertEqual(
            PerformMutationTesting.followingRunLimit(buildTimeout: 3_600, baselineSeconds: 100, checkRunSeconds: 200),
            1_000
        )
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
