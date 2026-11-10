@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingXcodeWorkersTests {
    // A run with no mutant on that fails on a simulator shows that the tests need what it lacks, or fail one at a
    // time: the run tests one mutant at a time on the test command's destination, as with one worker, and says why.
    func test_aFailedCheckRun_fallsBackToOneWorker_onTheTestCommandsDestination() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, launchFailed)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        let choice = WorkerChoice(
            asked: 2,
            used: 1,
            unsupportedReason: "worker 1's run with no mutant on, on its simulator, didn't pass: Simulator device "
                + "failed to launch com.example.MacCloud-client-iOS. (its log is no-mutant run worker 1.log)",
            mutantsToTest: 4,
            onSimulators: true,
            fellBack: true
        )
        XCTAssertEqual(choices(), [choice])
        XCTAssertEqual(fileManager.createdFiles["/logs/no-mutant run worker 1.log"], Data(launchFailed.utf8))
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
        assertTestedOnOneWorker()
        // The session still names the deleted simulators' workers, for their files, but no mutant runs on one.
        XCTAssertEqual(runs(on: "SIM-0").count, 0)
    }

    // A check run doesn't build, but runs the tests one at a time, so it has buildTimeout's limit. One stopped there
    // falls back to one worker, as one that failed does, and says why.
    func test_aCheckRunPastTheBuildTimeout_fallsBackToOneWorker() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            buildTimeout: 900
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.endingsWithoutBuildingWritingTo["no-mutant run worker 1"] = .timedOut
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.timeLimitsWithoutBuilding.prefix(2), [900, 900])
        XCTAssertEqual(choices().map(\.unsupportedReason), [
            "worker 1's run with no mutant on, on its simulator, didn't end within 900 s (buildTimeout) (its log is "
                + "no-mutant run worker 1.log)",
        ])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
    }

    // As a mutant's run does: the simulator's first install and launch, all at once on new simulators, is where it is
    // likeliest to fail to launch a run. The run runs once more in its place, on its worker, and the workers are kept
    // when it passes. The first run's log is kept beside the second's.
    func test_aCheckRunTheSimulatorFailedToLaunch_runsOnceMore_andTheWorkersAreKeptWhenItPasses() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.firstTestRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, launchFailed)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        let checks = ioDelegate.configurationsWithoutBuilding.compactMap(\.xcodeWorker)
        // Worker 0's check run, and the timed test run.
        XCTAssertEqual(checks.filter { $0 == worker(0) }.count, 2)
        XCTAssertEqual(checks.filter { $0 == worker(1) }.count, 2)
        XCTAssertEqual(choices().map(\.used), [2])
        XCTAssertEqual(choices().map(\.unsupportedReason), [nil])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(
            fileManager.createdFiles["/logs/no-mutant run worker 1 (launch failed).log"],
            Data(launchFailed.utf8)
        )
        XCTAssertEqual(fileManager.createdFiles["/logs/no-mutant run worker 1.log"], Data("timed test run log".utf8))
        XCTAssertNil(fileManager.createdFiles["/logs/no-mutant run worker 0 (launch failed).log"])
        // The second run's output is moved; the first's, which it wrote over, is kept from its text.
        XCTAssertTrue(
            ioDelegate.keptOutputs.contains {
                $0 == ("/logs/running/no-mutant run worker 1", "/logs/no-mutant run worker 1.log")
            },
            "\(ioDelegate.keptOutputs)"
        )
        XCTAssertFalse(
            ioDelegate.keptOutputs.contains { $0.path == "/logs/no-mutant run worker 1 (launch failed).log" },
            "\(ioDelegate.keptOutputs)"
        )
    }

    // A second failure to launch it still falls back to one worker, and both runs keep their logs.
    func test_aCheckRunTheSimulatorFailsToLaunchTwice_fallsBackToOneWorker_keepingBothLogs() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let launchFailed = loadFixture("SimulatorTrouble/launch_beforeEstablishingConnection.log")
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, launchFailed)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        let checks = ioDelegate.configurationsWithoutBuilding.compactMap(\.xcodeWorker)
        XCTAssertEqual(checks.filter { $0 == worker(1) }.count, 2)
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices().map(\.used), [1])
        XCTAssertEqual(
            fileManager.createdFiles["/logs/no-mutant run worker 1 (launch failed).log"],
            Data(launchFailed.utf8)
        )
        XCTAssertEqual(fileManager.createdFiles["/logs/no-mutant run worker 1.log"], Data(launchFailed.utf8))
        assertTestedOnOneWorker()
    }

    // A simulator that is gone would fail the run again the same way: it isn't run again, and the run falls back.
    func test_aCheckRunWhoseSimulatorIsGone_isNotRunAgain_andFallsBackToOneWorker() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let gone = loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")
        ioDelegate.firstTestRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, gone)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        let checks = ioDelegate.configurationsWithoutBuilding.compactMap(\.xcodeWorker)
        XCTAssertEqual(checks.filter { $0 == worker(1) }.count, 1)
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices().map(\.used), [1])
        XCTAssertNil(fileManager.createdFiles["/logs/no-mutant run worker 1 (launch failed).log"])
        XCTAssertEqual(fileManager.createdFiles["/logs/no-mutant run worker 1.log"], Data(gone.utf8))
        assertTestedOnOneWorker()
    }

    func test_simulatorsThatCanNotBeMade_fallBackToOneWorker() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 2 like \(destination) for /project_mutated",
        ])
        XCTAssertEqual(choices().map(\.unsupportedReason), [reason])
        XCTAssertEqual(checkRuns, [])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
        assertTestedOnOneWorker()
    }

    func test_simulatorsThatDoNotBoot_areDeleted_andFallBackToOneWorker() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let reason = "`xcrun simctl bootstatus SIM-1 -b` didn't finish within 300 seconds"
        workerSimulators.booting(throwing: WorkerSimulatorsUnavailable(reason: reason))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices().map(\.unsupportedReason), [reason])
        XCTAssertEqual(checkRuns, [])
        assertTestedOnOneWorker()
    }

    // Such a line would stop a run, or count a timed-out run killed, though every test passed.
    func test_aCheckRunThatPrintsWhatLooksLikeAFailedTest_makesFailedTestLinesUnreliable() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 0"] = (
            .passed, "Test Case '-[AppTests.ParserTests testFails]' failed (0.002 seconds).\n** TEST SUCCEEDED **"
        )

        _ = try await sut.run(with: state)

        XCTAssertEqual(Set(ioDelegate.configurations.map(\.failedTestLinesAreReliable)), [false])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertEqual(
            try resultsFiles.records(ResultsHeader.self).map(\.failedTestLookalikes),
            [[.init(name: "-[AppTests.ParserTests testFails]", file: nil)]]
        )
    }

    // A failed baseline throws while the simulators boot: their boot is cancelled and awaited, and they are deleted
    // once the work has ended, as after any other end.
    func test_aFailedBaseline_leavesTheSimulatorsToBeDeletedOnceTheWorkHasEnded() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(checkRuns, [])
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    // A stop during the baseline cancels the boot with it; the simulators are deleted once the work has ended.
    func test_aStopDuringTheBaseline_leavesTheSimulatorsToBeDeletedOnceTheWorkHasEnded() async throws {
        ioDelegate.testSuiteOutcomes = [.passed]
        ioDelegate.whileRunningBaseline = { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(checkRuns, [])
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    // A stop while the simulators boot, once the baseline has passed, cuts the boot short, as it does `simctl`'s, and
    // stops the run as one during the baseline does: it isn't why the run tests one mutant at a time, so no number of
    // workers is said, and no header is written. The simulators are deleted once the work has ended.
    func test_aStopWhileTheSimulatorsBoot_onceTheBaselinePassed_stopsTheRun_ratherThanFallingBack() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        workerSimulators.booting(throwing: CancellationError())
        let choices = sentChoices()

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(choices(), [])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self), [])
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    // As is a stop while the simulators are deleted after a failed check run.
    func test_aStopWhileTheSimulatorsAreDeleted_afterAFailedCheckRun_stopsTheRun_ratherThanFallingBack() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, "** TEST FAILED **")
        workerSimulators.removingAll { withUnsafeCurrentTask { $0?.cancel() } }
        let choices = sentChoices()

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices(), [])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self), [])
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
    }
}
