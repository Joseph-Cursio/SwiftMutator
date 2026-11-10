@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingLoneWorkerTests {
    // As with several workers: every run on it would fail, so mutation testing stops, naming worker 0.
    func test_oneWorker_aSimulatorThatIsGone_stopsMutationTesting() async throws {
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")]

        do {
            _ = try await sut.run(with: state)
            XCTFail("expected an abort")
        } catch let MuterError.mutationTestingAborted(reason: .simulatorUnavailable(worker, _, log)) {
            XCTAssertEqual(worker, 0)
            XCTAssertEqual(log?.hasSuffix(" (simulator gone).log"), true, String(describing: log))
        }
    }

    func test_oneWorker_aRunTheSimulatorFailedToLaunch_runsAgainOnIt() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 7)
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/launch_preflightBusy.log")]
        var repeated: [RepeatedRun] = []
        whenSent(.runRepeatedAfterLaunchFailure) { event in
            if let run = event.object as? RepeatedRun { repeated.append(run) }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(repeated.map(\.worker), [0])
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 7))
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 6)
    }

    // The mutants run one at a time, so a timeout had no other run's load to blame.
    func test_oneWorker_timeoutsAreNotRunAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .timeout] + Array(repeating: .failed, count: 4)
        var reruns = 0
        whenSent(.timeoutRerunsStarted) { _ in reruns += 1 }

        _ = try await sut.run(with: state)

        XCTAssertEqual(reruns, 0)
        XCTAssertEqual(ioDelegate.configurations.count, 6)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).filter { $0.rerun != nil }, [])
    }

    // The timed test run follows the check run, on the worker's simulator, so it doesn't pay for the simulator's first
    // install and launch, and sets the limit as SwiftPM's does: 5 times it, for one worker.
    func test_oneWorker_theTimedTestRunOnItsSimulator_setsTheDefaultTimeLimit() async throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        let runSeconds = Locked<[UInt64]>([40, 10])
        ioDelegate.whileRunningTestsWithoutBuilding = {
            let seconds = runSeconds.change { $0.removeFirst() }
            nanoseconds.change { $0 += seconds * 1_000_000_000 }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            ioDelegate.testLogs.prefix(3),
            ["/logs/running/baseline run", "/logs/running/no-mutant run worker 0", "/logs/running/timed test run"]
        )
        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.xcodeWorker), [worker0, worker0])
        // The check run's `.xctestrun`, then the timed run's, both with no mutant on, before the first mutant's.
        let firstMutant = state.mutationMapping[0].mutationSchemata[0]
        XCTAssertEqual(ioDelegate.schematas.prefix(3), [.null, .null, firstMutant])
        XCTAssertEqual(Set(ioDelegate.testRunFileNames), ["muter.xctestrun"])
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), Array(repeating: 50, count: 6))
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.testRunSeconds, 10)
        XCTAssertEqual(header.timeoutSeconds, 50)
        XCTAssertEqual(fileManager.createdFiles["/logs/timed test run.log"], Data("timed test run log".utf8))
        XCTAssertTrue(
            ioDelegate.keptOutputs.contains { $0 == ("/logs/running/timed test run", "/logs/timed test run.log") },
            "\(ioDelegate.keptOutputs)"
        )
    }

    // As a mutant's run does: the first run's log is kept from its text, beside the second's.
    func test_oneWorker_aTimedTestRunTheSimulatorFailedToLaunch_runsOnceMore_andKeepsBothLogs() async throws {
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.firstTestRunsWithoutBuildingWritingTo["timed test run"] = (.failed, launchFailed)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs.filter { $0 == "/logs/running/timed test run" }.count, 2)
        XCTAssertEqual(fileManager.createdFiles["/logs/timed test run (launch failed).log"], Data(launchFailed.utf8))
        XCTAssertEqual(fileManager.createdFiles["/logs/timed test run.log"], Data("timed test run log".utf8))
    }

    // Without a passing timed test run, a mutant's run may take 3 times the run with no mutant on, when it took longer
    // than the baseline, which spread its tests over parallel testing's clones; the worker tests one at a time.
    func test_oneWorker_aFailedTimedTestRun_leavesTheDefaultTimeLimitToTheRunWithNoMutantOn() async throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += 40_000_000_000 } }
        ioDelegate.testRunsWithoutBuildingWritingTo["timed test run"] = (.failed, "** TEST FAILED **")

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), Array(repeating: 120, count: 6))
        XCTAssertNil(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).testRunSeconds)
    }

    // On the destination, after a fallback, the timed test run tests there, as a mutant's run then does.
    func test_oneWorker_aFailedRunWithNoMutantOn_timesTheTestRunOnTheDestination() async throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += 40_000_000_000 } }
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 0"] = (.failed, "** TEST FAILED **")

        _ = try await sut.run(with: state)

        assertTestedOnTheDestination()
        XCTAssertEqual(
            ioDelegate.configurationsWithoutBuilding.last?.xcodeWorker,
            ioDelegate.configurations.first?.xcodeWorker
        )
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), Array(repeating: 200, count: 6))
    }

    // Several workers' timeouts are run again, at lower load, and SwiftPM's timed run tests as a mutant's does.
    func test_theDefaultTimeLimit_isThreeTimesTheLongerOfTheBaselineAndALoneWorkersRunWithNoMutantOn() {
        func limit(
            _ testRunSeconds: TimeInterval?,
            _ baselineSeconds: TimeInterval,
            _ workers: Int,
            checkRun: TimeInterval?
        ) -> TimeInterval {
            let pool = SimulatorWorkerSetup.Workers(
                count: workers,
                unavailable: nil,
                configuration: MuterConfiguration(),
                xcodeWorkers: [],
                checkRunSeconds: checkRun
            )
            return PerformMutationTesting.defaultTimeout(
                testRunSeconds: testRunSeconds, baselineSeconds: baselineSeconds, on: pool
            )
        }

        XCTAssertEqual(limit(nil, 50, 1, checkRun: nil), 150)
        XCTAssertEqual(limit(nil, 50, 1, checkRun: 200), 600)
        XCTAssertEqual(limit(nil, 50, 1, checkRun: 20), 150)
        XCTAssertEqual(limit(nil, 1, 1, checkRun: 2), 10)
        XCTAssertEqual(limit(nil, 50, 2, checkRun: 200), 150)
        XCTAssertEqual(limit(10, 50, 1, checkRun: 200), 50)
    }

    func test_oneWorker_aFailedBaseline_leavesTheSimulatorToBeDeletedOnceTheWorkHasEnded() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(workerSimulators.calls.dropFirst().first, "prepare 1 like \(destination) for /project_mutated")
        XCTAssertEqual(checkRuns, [])
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    func test_oneWorker_aStopDuringTheBaseline_leavesTheSimulatorToBeDeletedOnceTheWorkHasEnded() async throws {
        ioDelegate.whileRunningBaseline = { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(workerSimulators.calls.dropFirst().first, "prepare 1 like \(destination) for /project_mutated")
        XCTAssertEqual(checkRuns, [])
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    // A stop isn't why the run tests on the destination: no worker is said, and no header is written.
    func test_oneWorker_aStopDuringTheGuardsDelete_stopsTheRun_ratherThanFallingBack() async throws {
        ioDelegate.baselineTestLog = spreadBaseline
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
