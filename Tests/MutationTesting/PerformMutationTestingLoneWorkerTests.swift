@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// One xcodebuild worker, which tests on a simulator of its own when that should be faster than on the test command's
/// destination (`SimulatorWorkerSetup.oneWorkerPlan(for:state:)`).
final class PerformMutationTestingLoneWorkerTests: MuterTestCase {
    private let state = MutationTestState()

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, _ in [] },
        removeWorkerDirectories: { _ in }
    )

    private let destination = "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"
    private let checkRun = "runTestsWithoutBuilding(using:savingResultsIntoFileNamed:)"
    /// A baseline whose tests ran on one clone, as the destination's runs would, each paying for its clone and boot.
    private let oneCloneBaseline = """
    Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.010 seconds)
    Test case 'SumTests.difference()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.010 seconds)
    ** TEST SUCCEEDED **
    """
    /// A baseline that spread 12 s of tests over two clones.
    private let spreadBaseline = """
    Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (5.000 seconds)
    Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (124)' (7.000 seconds)
    ** TEST SUCCEEDED **
    """

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        configure()
        state.apply([
            .testDiagnosticsOptionChecked(canBeTurnedOff: true),
            .projectXCTestRun(.parallelizing),
        ])
        state.mutationMapping = try (1...6).map(makeSchemataMapping(line:))
        ioDelegate.baselineTestLog = oneCloneBaseline
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 6)
    }

    // The simulator is made before the baseline, booted while it runs, and checked by one run with no mutant on, one
    // test at a time. The mutants then run on it in job order, from `muter.xctestrun`, with worker 0's derived data.
    func test_oneWorker_onAParallelizingProject_testsInOrderOnASimulatorOfItsOwn() async throws {
        var atTheBaseline: [String] = []
        ioDelegate.whileRunningBaseline = { [unowned self] _ in atTheBaseline = workerSimulators.calls }
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            Array(atTheBaseline.prefix(2)),
            ["sweep /project_mutated", "prepare 1 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
        ])
        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.xcodeWorker), [worker0])
        XCTAssertTrue(
            ioDelegate.configurationsWithoutBuilding.first?.testWithoutBuildArguments(with: "muter.xctestrun")
                .joined(separator: " ").contains("-parallel-testing-enabled NO") == true
        )
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
        let mutants = zip(ioDelegate.schematas, ioDelegate.testRunFileNames).filter { $0.0 != .null }
        XCTAssertEqual(mutants.map(\.0.id), state.mutationMapping.flatMap(\.mutationSchemata).map(\.id))
        XCTAssertEqual(Set(mutants.map(\.1)), ["muter.xctestrun"])
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.worker), Array(repeating: 0, count: 6))
        XCTAssertEqual(choices().map(\.sentence), ["👷 Testing one mutant at a time, on a simulator of its own."])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1])
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    // The session keeps the deleted simulator's worker, for its files, but no mutant may run on it.
    func test_oneWorker_aFailedCheckRun_testsOnTheTestCommandsDestination_andSaysWhy() async throws {
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 0"] = (.failed, "** TEST FAILED **")
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: worker 0's run with no mutant on, on "
                + "its simulator, didn't pass (its log is no-mutant run worker 0.log).",
        ])
        assertTestedOnTheDestination()
        XCTAssertFalse(
            ioDelegate.configurations.contains {
                $0.testWithoutBuildArguments(with: "muter.xctestrun").contains("-parallel-testing-enabled")
            }
        )
    }

    func test_oneWorker_simulatorsThatCanNotBeMade_fallBack_andSayWhy() async throws {
        let reason = "`xcrun simctl clone 693E96A4 swiftmutator-0123abcd-1-2-w0` failed with exit code 149"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            workerSimulators.calls,
            ["sweep /project_mutated", "prepare 1 like \(destination) for /project_mutated"]
        )
        XCTAssertEqual(
            choices().map(\.sentence),
            ["👷 Testing one mutant at a time on the test command's destination: \(reason)."]
        )
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        assertTestedOnTheDestination()
    }

    func test_oneWorker_simulatorsThatDoNotBoot_areDeleted_andFallBack() async throws {
        let reason = "`xcrun simctl bootstatus SIM-0 -b` didn't finish within 300 seconds"
        workerSimulators.booting(throwing: WorkerSimulatorsUnavailable(reason: reason))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertEqual(
            choices().map(\.sentence),
            ["👷 Testing one mutant at a time on the test command's destination: \(reason)."]
        )
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        assertTestedOnTheDestination()
    }

    // As a device's bare `id=` does: the run tests on it as it would have without a word, unless the key asked.
    func test_oneWorker_aDestinationThatResolvesToNoSimulator_isQuiet() async throws {
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason, destinationUnresolved: true)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().compactMap(\.sentence), [])
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aDestinationThatResolvesToNoSimulator_isSaid_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: true)
        let reason = "no available simulator matches `-destination \(destination)`, or more than one does"
        workerSimulators.preparing(.failure(WorkerSimulatorsUnavailable(reason: reason, destinationUnresolved: true)))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            choices().map(\.sentence),
            ["👷 Testing one mutant at a time on the test command's destination: \(reason)."]
        )
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aMacDestination_makesNoSimulator_andSaysNothing() async throws {
        let choices = sentChoices()
        let destinations = ["platform=macOS", "platform=macOS,variant=Mac Catalyst", "generic/platform=iOS Simulator"]
        for destination in destinations {
            configure(destination: destination)
            ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 6)

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(workerSimulators.calls, Array(repeating: "sweep /project_mutated", count: 3))
        XCTAssertEqual(choices().count, 3)
        XCTAssertEqual(choices().compactMap(\.sentence), [])
    }

    func test_oneWorker_aMacDestination_saysWhy_whenOneWorkerSimulatorIsTrue() async throws {
        configure(destination: "platform=macOS", oneWorkerSimulator: true)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: a simulator of its own needs a first "
                + "`-destination` that is a simulator.",
        ])
    }

    // Without parallel testing, the destination's runs already test one at a time on the user's simulator, with no
    // clone to pay for.
    func test_oneWorker_aProjectWhoseTestsDoNotParallelize_makesNoSimulator() async throws {
        state.apply([.projectXCTestRun(muterCore.XCTestRun())])
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aProjectWhoseTestsDoNotParallelize_getsOne_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: true)
        state.apply([.projectXCTestRun(muterCore.XCTestRun())])

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.dropFirst().first, "prepare 1 like \(destination) for /project_mutated")
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    func test_oneWorker_fewerThanSixMutants_makesNoSimulator_unlessOneWorkerSimulatorIsTrue() async throws {
        state.mutationMapping = try (1...5).map(makeSchemataMapping(line:))
        _ = try await sut.run(with: state)
        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])

        configure(oneWorkerSimulator: true)
        state.mutationMapping = try (1...2).map(makeSchemataMapping(line:))
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        _ = try await sut.run(with: state)
        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
        ])
    }

    // One mutant needs no simulator of its own, whatever the key says, and nor does `--mutant`'s.
    func test_oneMutant_makesNoSimulator_withOneWorker() async throws {
        configure(oneWorkerSimulator: true)
        state.mutationMapping = try [makeSchemataMapping(line: 1)]
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
    }

    func test_aSelectedMutant_makesNoSimulator_withOneWorker() async throws {
        configure(oneWorkerSimulator: true)
        let key = MutantKey(path: "file1.swift", mutationOperatorId: .ror, line: 1, column: 0, occurrence: 0)
        state.apply([.mutantSelected(key)])
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
    }

    func test_oneWorkerSimulatorFalse_makesNone() async throws {
        configure(oneWorkerSimulator: false)
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(choices().compactMap(\.sentence), [])
        assertTestedOnTheDestination()
    }

    // They reach the baseline, which then tests unlike a mutant's run, which doesn't have them.
    func test_oneWorker_argumentsThatTuneParallelTesting_keepTheDestination_andSayWhy() async throws {
        let tunings = [
            (["-parallel-testing-enabled", "YES"], "-parallel-testing-enabled YES"),
            (["-parallel-testing-worker-count", "3"], "-parallel-testing-worker-count"),
            (["-maximum-parallel-testing-workers", "2"], "-maximum-parallel-testing-workers"),
            (["-parallelize-tests-among-destinations"], "-parallelize-tests-among-destinations"),
        ]
        let choices = sentChoices()
        for (arguments, _) in tunings {
            configure(arguments: arguments)
            ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 6)

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(workerSimulators.calls, Array(repeating: "sweep /project_mutated", count: 4))
        XCTAssertEqual(choices().map(\.sentence), tunings.map { _, option in
            "👷 Testing one mutant at a time on the test command's destination: the test command's arguments set "
                + "`\(option)`, so its baseline doesn't show how a mutant's run would test; `oneWorkerSimulator: true` "
                + "tests on a simulator of its own anyway."
        })
    }

    // A baseline that tests one test at a time prints no line for a test on a clone, which says nothing against it.
    func test_oneWorker_parallelTestingOffInTheArguments_stillGetsASimulator_withoutTheBaselineGuard() async throws {
        configure(arguments: ["-parallel-testing-enabled", "NO"])
        ioDelegate.baselineTestLog = "Test Case 'SumTests.sum()' passed (0.01 seconds).\n** TEST SUCCEEDED **"

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    func test_oneWorker_aBaselineSpreadOverClones_deletesTheSimulatorBeforeItsCheckRun() async throws {
        ioDelegate.baselineTestLog = spreadBaseline
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [
            "sweep /project_mutated",
            "prepare 1 like \(destination) for /project_mutated",
            "boot SIM-0",
            "removeAll",
        ])
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: the baseline's parallel testing spread "
                + "12.0 s of tests over 2 clones, which one at a time on one simulator could make slower; "
                + "`oneWorkerSimulator: true` tests on one anyway.",
        ])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aShortSuiteSpreadOverClones_keepsTheSimulator() async throws {
        ioDelegate.baselineTestLog = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (1.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (124)' (2.000 seconds)
        """

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    // The baseline tests on every `-destination`, each with clones of its own, but a mutant's run only on the first:
    // its 8 s of tests over 2 clones keep the simulator, whatever the second's add up to.
    func test_oneWorker_aBaselineOnSeveralDestinations_isJudgedOnTheFirst() async throws {
        configure(arguments: ["-destination", "platform=iOS Simulator,name=iPad Air"])
        ioDelegate.baselineTestLog = """
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPad Air - App (201)' (4.000 seconds)
        Test case 'SumTests.sum()' passed on 'Clone 1 of iPhone 17 Pro - App (101)' (4.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPhone 17 Pro - App (102)' (4.000 seconds)
        Test case 'ParserTests.parse()' passed on 'Clone 2 of iPad Air - App (202)' (4.000 seconds)
        """

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    func test_oneWorker_aBaselineWithoutCloneLines_deletesTheSimulator_andSaysWhy() async throws {
        ioDelegate.baselineTestLog = "** TEST SUCCEEDED **"
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time on the test command's destination: the baseline printed no parallel "
                + "testing line to tell how many clones its tests ran on; `oneWorkerSimulator: true` tests on a "
                + "simulator of its own anyway.",
        ])
        assertTestedOnTheDestination()
    }

    func test_oneWorker_aBaselineSpreadOverClones_keepsTheSimulator_whenOneWorkerSimulatorIsTrue() async throws {
        configure(oneWorkerSimulator: true)
        ioDelegate.baselineTestLog = spreadBaseline

        _ = try await sut.run(with: state)

        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        XCTAssertTrue(ioDelegate.methodCalls.contains(checkRun))
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
    }

    // As with several workers: every run on it would fail, so mutation testing stops, naming worker 0.
    func test_oneWorker_aSimulatorThatIsGone_stopsMutationTesting() async throws {
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")]

        do {
            _ = try await sut.run(with: state)
            XCTFail("expected an abort")
        } catch let MuterError.mutationTestingAborted(reason: .simulatorUnavailable(worker, _, log)) {
            XCTAssertEqual(worker, 0)
            XCTAssertTrue(log?.hasSuffix(" (simulator gone).log") == true, String(describing: log))
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

    // The baseline spread its tests over parallel testing's clones, but the worker tests one test at a time, as its run
    // with no mutant on did, so a mutant's run may take 3 times that run, when it took longer than the baseline.
    func test_oneWorker_aRunWithNoMutantOnLongerThanTheBaseline_setsTheDefaultTimeLimit() async throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += 40_000_000_000 } }

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), Array(repeating: worker0, count: 6))
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), Array(repeating: 120, count: 6))
    }

    // On the destination, after a fallback, a mutant's run tests as the baseline did, whose time sets the limit.
    func test_oneWorker_aFailedRunWithNoMutantOn_leavesTheDefaultTimeLimitToTheBaseline() async throws {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += 40_000_000_000 } }
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 0"] = (.failed, "** TEST FAILED **")

        _ = try await sut.run(with: state)

        assertTestedOnTheDestination()
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            Array(repeating: PerformMutationTesting.minimumDefaultTimeout, count: 6)
        )
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
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
        XCTAssertFalse(workerSimulators.calls.contains("removeAll"))
        await current.interruption.workEnded()
        XCTAssertEqual(workerSimulators.calls.last, "removeAll")
    }

    func test_oneWorker_aStopDuringTheBaseline_leavesTheSimulatorToBeDeletedOnceTheWorkHasEnded() async throws {
        ioDelegate.whileRunningBaseline = { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(workerSimulators.calls.dropFirst().first, "prepare 1 like \(destination) for /project_mutated")
        XCTAssertFalse(ioDelegate.methodCalls.contains(checkRun))
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

    /// Worker 0's part of the configuration, on the spy's simulator `SIM-0`.
    private var worker0: MuterConfiguration.XcodeWorker {
        MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData",
            destination: "platform=iOS Simulator,id=SIM-0",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        )
    }

    /// An xcodebuild test command with `-destination destination`, `arguments` and the key, and no workers asked for.
    private func configure(
        destination: String? = nil,
        arguments: [String] = [],
        oneWorkerSimulator: Bool? = nil
    ) {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination ?? self.destination] + arguments + ["test"],
            oneWorkerSimulator: oneWorkerSimulator
        )
    }

    /// Asserts that every mutant was tested from `muter.xctestrun`, on the test command's destination, with parallel
    /// testing as the scheme has it, and none on the simulator that was deleted.
    private func assertTestedOnTheDestination(file: StaticString = #filePath, line: UInt = #line) {
        let firstWorker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(
            ioDelegate.configurations.map(\.xcodeWorker),
            Array(repeating: firstWorker, count: 6),
            file: file,
            line: line
        )
        let destinations = ioDelegate.configurations.map { configuration in
            configuration.testWithoutBuildArguments(with: "muter.xctestrun").dropFirst(2).first
        }
        XCTAssertEqual(Set(destinations), [destination], file: file, line: line)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [1], file: file, line: line)
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
