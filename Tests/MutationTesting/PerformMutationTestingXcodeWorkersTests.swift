@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// An xcodebuild project's workers, each on a simulator of its own.
final class PerformMutationTestingXcodeWorkersTests: MuterTestCase {
    private let state = MutationTestState()
    private var clonedCounts: [Int] = []

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [unowned self] _, count in
            clonedCounts.append(count)
            return []
        },
        removeWorkerDirectories: { _ in }
    )

    private let destination = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"
    private let checkRun = "runTestsWithoutBuilding(using:savingResultsIntoFileNamed:)"

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2
        )
        state.apply([.testDiagnosticsOptionChecked(canBeTurnedOff: true)])
        state.mutationMapping = try (1...4).map(makeSchemataMapping(line:))
    }

    // The simulators are made before the baseline, which they boot during, and checked once it has passed. Only then
    // is the number of workers said, and the header written with it, before any mutant's run.
    func test_theSimulatorsAreMadeBeforeTheBaseline_andCheckedBeforeTheWorkersAreSaid() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        var atTheBaseline: [String] = []
        ioDelegate.whileRunningBaseline = { [unowned self] _ in atTheBaseline = workerSimulators.calls }
        var atTheChoice: (simulators: [String], delegate: [String], headers: Int)?
        whenSent(.workersChosen) { [unowned self] _ in
            let headers = (try? resultsFiles.records(ResultsHeader.self).count) ?? -1
            atTheChoice = (workerSimulators.calls, ioDelegate.methodCalls, headers)
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            Array(atTheBaseline.prefix(2)),
            ["sweep /project_mutated", "prepare 2 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(atTheChoice?.simulators, [
            "sweep /project_mutated",
            "prepare 2 like \(destination) for /project_mutated",
            "boot SIM-0 SIM-1",
        ])
        // The check runs run at once, so in no set order.
        XCTAssertEqual(atTheChoice?.delegate.first, "benchmarkTests(using:savingResultsIntoFileNamed:)")
        XCTAssertEqual(
            atTheChoice?.delegate.dropFirst().sorted(),
            [checkRun, checkRun, "switchOn(schemata:for:at:named:)", "switchOn(schemata:for:at:named:)"]
        )
        XCTAssertEqual(atTheChoice?.headers, 0)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 4)
    }

    // Each check run tests from its worker's own `.xctestrun`, with no mutant switched on in it, on its simulator, one
    // test at a time, and keeps its log.
    func test_eachSimulatorRunsTheTestsWithNoMutantOn_fromItsWorkersTestRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        let checks = ioDelegate.configurationsWithoutBuilding.compactMap(\.xcodeWorker)
        XCTAssertEqual(checks.sorted { $0.testRunFile > $1.testRunFile }, [worker(0), worker(1)])
        XCTAssertEqual(
            Set(ioDelegate.testLogs.filter { $0.contains("no-mutant") }),
            ["/logs/running/no-mutant run worker 0", "/logs/running/no-mutant run worker 1"]
        )
        let switchedOff = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 == .null }.map(\.1)
        XCTAssertEqual(switchedOff.sorted(), ["muter-worker1.xctestrun", "muter.xctestrun"])
        XCTAssertEqual(
            fileManager.createdFiles["/logs/no-mutant run worker 1.log"],
            Data("timed test run log".utf8)
        )
    }

    // Nothing is copied or built again: every worker tests in the mutated project, from the baseline's build, on its
    // own simulator, from its own `.xctestrun`, with its own derived data, one test at a time.
    func test_eachWorkerTestsInTheMutatedProject_onItsOwnSimulator() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        let result = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [])
        XCTAssertEqual(Set(ioDelegate.workingDirectories), [state.mutatedProjectDirectoryURL])
        XCTAssertEqual(distinct(ioDelegate.configurations.compactMap(\.xcodeWorker)).count, 2)
        let workers = [worker(0), worker(1)]
        XCTAssertTrue(ioDelegate.configurations.allSatisfy { $0.xcodeWorker.map(workers.contains) == true })
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
        let mutantFiles = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 != .null }.map(\.1)
        XCTAssertEqual(mutantFiles.count, 4, "each mutant switched on once")
        XCTAssertEqual(Set(mutantFiles), ["muter.xctestrun", "muter-worker1.xctestrun"])
        XCTAssertEqual(outcomes(in: result), Array(repeating: .failed, count: 4))
    }

    func test_theWorkersUsed_areSaidToTestOnSimulators() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.sentence), ["👷 Testing 2 mutants at a time, each on a simulator of its own."])
    }

    // The run's other files go as its clones would: the mutated project keeps only worker 0's `.xctestrun`. The
    // simulators go once the work has ended.
    func test_theWorkersFiles_areRemovedAtTheEnd_andTheirSimulatorsOnceTheWorkHasEnded() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            fileManager.paths.filter { $0.hasSuffix(".DerivedData") || $0.hasSuffix(".xctestrun") }.sorted(),
            [
                "/project_mutated.DerivedData",
                "/project_mutated/muter-worker1.xctestrun",
                "/project_mutated_worker1.DerivedData",
            ]
        )
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

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
            onSimulators: true
        )
        XCTAssertEqual(choices(), [choice])
        XCTAssertEqual(fileManager.createdFiles["/logs/no-mutant run worker 1.log"], Data(launchFailed.utf8))
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
        assertTestedOnOneWorker()
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
        XCTAssertEqual(checks.filter { $0 == worker(0) }.count, 1)
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
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
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
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
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
    }

    // A failed baseline throws while the simulators boot: their boot is cancelled and awaited, and they are deleted
    // once the work has ended, as after any other end.
    func test_aFailedBaseline_leavesTheSimulatorsToBeDeletedOnceTheWorkHasEnded() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
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
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
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

    // One mutant needs no simulator of its own: it tests on the test command's destination.
    func test_oneMutant_makesNoSimulator() async throws {
        state.mutationMapping = try [makeSchemataMapping(line: 1)]
        ioDelegate.testSuiteOutcomes = [.passed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
    }

    // A Mac app's test runs share its defaults, saved state and container, so it tests one mutant at a time, on the
    // test command's destination, and says why.
    func test_aMacDestination_makesNoSimulator_andSaysWhy() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"],
            mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        XCTAssertEqual(choices().map(\.unsupportedReason), [state.muterConfiguration.parallelWorkersUnsupportedReason])
        XCTAssertEqual(choices().map(\.used), [1])
        assertTestedOnOneWorker()
    }

    // As on one worker: the run the simulator failed to launch runs again, on its own worker, and the second is
    // recorded.
    func test_aRunTheSimulatorFailedToLaunch_runsAgainOnItsWorker() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 5)
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/launch_preflightBusy.log")]
        var repeated: [RepeatedRun] = []
        whenSent(.runRepeatedAfterLaunchFailure) { event in
            if let run = event.object as? RepeatedRun { repeated.append(run) }
        }

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(repeated.first)
        XCTAssertEqual(repeated.count, 1)
        let worker = worker(run.worker)
        let runsOnIt = ioDelegate.configurations.filter { $0.xcodeWorker == worker }
        XCTAssertGreaterThanOrEqual(runsOnIt.count, 2)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 4)
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
    }

    // A worker whose simulator is gone would fail every run: mutation testing stops, naming it, and a resume makes new
    // simulators.
    func test_aWorkersSimulatorThatIsGone_stopsMutationTesting() async throws {
        state.mutationMapping = try (1...2).map(makeSchemataMapping(line:))
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")]

        do {
            _ = try await sut.run(with: state)
            XCTFail("expected an abort")
        } catch let MuterError.mutationTestingAborted(reason: .simulatorUnavailable(worker, line, log)) {
            XCTAssertTrue([0, 1].contains(worker))
            XCTAssertEqual(
                line, "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
            )
            XCTAssertTrue(log?.hasSuffix(" (simulator gone).log") == true, String(describing: log))
        }
    }

    // The timeouts are tested again on a quarter of the workers, at least one: worker 0, on its simulator.
    func test_timeoutsAreRunAgainOnTheFirstWorkersSimulator() async throws {
        state.mutationMapping = try (1...2).map(makeSchemataMapping(line:))
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .timeout, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.count, 4)
        XCTAssertEqual(ioDelegate.configurations.suffix(2).map(\.xcodeWorker), [worker(0), worker(0)])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).filter { $0.rerun != nil }.count, 2)
    }

    // As on one worker: a mutant whose worker's `.xctestrun` can't be written isn't tested with another mutant on.
    // The check runs have written theirs by then.
    func test_aMutantThatCanNotBeSwitchedOn_stopsMutationTesting_beforeItsRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let error = CocoaError(.fileWriteOutOfSpace)
        whenSent(.workersChosen) { [unowned self] _ in ioDelegate.switchOnError = error }
        let ids = state.mutationMapping.flatMap(\.mutationSchemata).map(\.id)

        await assertThrowsMuterError(try await sut.run(with: state)) { muterError in
            guard case let .mutationTestingAborted(reason: .mutantNotSwitchedOn(id, description)) = muterError else {
                return XCTFail("expected mutantNotSwitchedOn, got \(muterError)")
            }
            XCTAssertTrue(ids.contains(id), id)
            XCTAssertEqual(description, error.localizedDescription)
        }

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertEqual(try resultsFiles.records(MutantResult.self), [])
    }

    // Which worker tests a mutant, and when, changes no verdict: four workers record what one does.
    func test_fourWorkers_recordTheVerdictsOneWorkerDoes() async throws {
        state.mutationMapping = try (1...6).map(makeSchemataMapping(line:))
        let ids = state.mutationMapping.flatMap(\.mutationSchemata).map(\.id)
        let scripted: [TestSuiteOutcome] = [.failed, .passed, .runtimeError, .failed, .passed, .failed]
        ioDelegate.outcomesByMutant = Dictionary(uniqueKeysWithValues: zip(ids, scripted))
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        var verdicts: [[String: TestSuiteOutcome]] = []

        for workers in [1, 4] {
            state.muterConfiguration = MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-scheme", "App", "-destination", destination, "test"],
                mutationTestWorkers: workers
            )
            _ = try await sut.run(with: state)
            let results = try resultsFiles.records(MutantResult.self).dropFirst(verdicts.count * ids.count)
            verdicts.append(Dictionary(uniqueKeysWithValues: results.map { ($0.switchID, $0.outcome) }))
        }

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1, 4])
        XCTAssertEqual(Set(ioDelegate.configurations.compactMap(\.xcodeWorker?.destination)).count, 4)
        XCTAssertEqual(verdicts.first, Dictionary(uniqueKeysWithValues: zip(ids, scripted)))
        XCTAssertEqual(verdicts.last, verdicts.first)
    }

    /// Worker `number`'s part of the configuration, on the spy's simulator `SIM-<number>`.
    private func worker(_ number: Int) -> MuterConfiguration.XcodeWorker {
        MuterConfiguration.XcodeWorker(
            testRunFile: MutationTestingDelegate.testRunFileName(ofWorker: number),
            derivedData: MuterConfiguration.XcodeWorker.derivedData(
                ofWorker: number, in: state.mutatedProjectDirectoryURL
            ),
            destination: "platform=iOS Simulator,id=SIM-\(number)",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        )
    }

    /// Asserts that every mutant was tested one at a time, from `muter.xctestrun`, on the test command's destination,
    /// with parallel testing as the scheme has it.
    private func assertTestedOnOneWorker(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)", count: 4),
            file: file,
            line: line
        )
        let firstWorker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(
            distinct(ioDelegate.configurations.compactMap(\.xcodeWorker)),
            [firstWorker],
            file: file,
            line: line
        )
    }

    /// Each of `workers` once, in the order they first come.
    private func distinct(_ workers: [MuterConfiguration.XcodeWorker]) -> [MuterConfiguration.XcodeWorker] {
        workers.reduce(into: []) { distinct, worker in
            if !distinct.contains(worker) { distinct.append(worker) }
        }
    }

    /// The worker choices sent from now on, until the test ends.
    private func sentChoices() -> () -> [WorkerChoice] {
        var choices: [WorkerChoice] = []
        whenSent(.workersChosen) { event in
            if case let .workersChosen(choice) = event { choices.append(choice) }
        }
        return { choices }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    private func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// Each mutant's outcome, in job order, from what `run(with:)` returned.
    private func outcomes(in result: [MutationTestState.Change]) -> [TestSuiteOutcome] {
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else { return [] }
        return outcome.mutations.map(\.testSuiteOutcome)
    }

    private func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/file\(line).swift",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/file\(line).swift",
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
