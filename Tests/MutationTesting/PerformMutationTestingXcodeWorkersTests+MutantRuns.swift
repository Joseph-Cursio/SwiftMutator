@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingXcodeWorkersTests {
    // One mutant needs no simulator of its own: it tests on the test command's destination.
    func test_oneMutant_makesNoSimulator() async throws {
        state.mutationMapping = try [makeSchemataMapping(line: 1)]
        ioDelegate.testSuiteOutcomes = [.passed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
        XCTAssertEqual(checkRuns, [])
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
        XCTAssertEqual(checkRuns, [])
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
            XCTAssertEqual(log?.hasSuffix(" (simulator gone).log"), true, String(describing: log))
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
        whenSent(.workersChosen) { [ioDelegate] _ in ioDelegate.switchOnError = error }
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

    // A control run tests from its worker's `.xctestrun`, written with no mutant on, on that worker's simulator.
    func test_aControlRun_switchesEveryMutantOffInItsWorkersXCTestRun() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            controlRunEvery: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.switchedOnForControlRuns, [MutationSchema.null.id, MutationSchema.null.id])
        XCTAssertEqual(ioDelegate.controlRunDirectories, Array(repeating: state.mutatedProjectDirectoryURL, count: 2))
        XCTAssertTrue(
            ioDelegate.controlRunConfigurations.allSatisfy { [worker(0), worker(1)].contains($0.xcodeWorker) }
        )
        XCTAssertEqual(try resultsFiles.records(ControlRunResult.self).count, 2)
        XCTAssertEqual(ioDelegate.mutantsNotSwitchedOnForTheirRun, [])
    }

    // As for a mutant: a control run whose worker's `.xctestrun` can't be written would test the last mutant.
    func test_aControlRunThatCanNotSwitchTheMutantsOff_stopsMutationTesting_beforeItsRun() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            controlRunEvery: 1
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let error = CocoaError(.fileWriteOutOfSpace)
        // Only with no mutant on, so the mutant the other worker starts meanwhile is switched on.
        ioDelegate.switchOnFails = { $0 == .null }
        whenSent(.workersChosen) { [ioDelegate] _ in ioDelegate.switchOnError = error }

        var failed: Int?
        await assertThrowsMuterError(try await sut.run(with: state)) { muterError in
            guard case let .mutationTestingAborted(reason: .controlRunNotSwitchedOff(number, description)) = muterError
            else {
                return XCTFail("expected controlRunNotSwitchedOff, got \(muterError)")
            }
            failed = number
            XCTAssertEqual(description, error.localizedDescription)
        }

        // The first, unless the other worker's mutant finished before it began, and that worker took the second.
        let number = try XCTUnwrap(failed)
        XCTAssertTrue([1, 2].contains(number), "\(number)")
        XCTAssertEqual(ioDelegate.controlRunConfigurations, [])
        XCTAssertEqual(try resultsFiles.records(ControlRunResult.self), [])
        XCTAssertEqual(
            try resultsFiles.records(ResultsEnd.self).map(\.detail), ["controlRunNotSwitchedOff(number: \(number))"]
        )
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
}
