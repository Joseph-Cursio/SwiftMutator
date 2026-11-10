@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingParallelTests {
    func test_withTwoWorkers_eachMutantRunsInAWorkerDirectory() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        // The baseline, the worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]

        let result = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(removedClones, [[workerClone]])
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [workerClone])
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:workingDirectory:)", count: 2)
        )
        XCTAssertFalse(ioDelegate.methodCalls.contains("switchOn(schemata:for:at:named:)"))
        XCTAssertEqual(
            Set(ioDelegate.workingDirectories),
            [state.mutatedProjectDirectoryURL, workerClone]
        )

        // Outcomes keep the mutants' order, whichever worker finished first.
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else {
            XCTFail("Expected an outcome, got \(result)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [1, 2])
    }

    func test_outcomesKeepTheMutantsOrder_whenTheirRunsFinishOutOfOrder() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...4).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 4)
        // The first run to start waits until the last one has started, so the other worker runs the other three
        // mutants meanwhile. The wait is bounded, so the test can't hang.
        let lastRunStarted = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = lastRunStarted.wait(timeout: .now() + 5) }
            if number == 3 { lastRunStarted.signal() }
        }
        let finishedLines = linesOfSentOutcomes()

        let result = try await sut.run(with: state)

        XCTAssertNotEqual(finishedLines(), [1, 2, 3, 4], "the runs didn't finish out of order")
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else {
            XCTFail("Expected an outcome, got \(result)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [1, 2, 3, 4])
    }

    func test_workersAreCappedAtTheNumberOfMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1], "two mutants need one clone, not seven")
    }

    // Said, with why fewer than asked for, once the baseline has passed.
    func test_theWorkersUsed_areSaid() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        var choices: [WorkerChoice] = []
        let subscription = runEvents.observe(.workersChosen) { event in
            if case let .workersChosen(choice) = event { choices.append(choice) }
        }
        defer { subscription.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices, [WorkerChoice(asked: 8, used: 2, unsupportedReason: nil, mutantsToTest: 2)])
    }

    // The progress bar's first estimate spreads the mutants over the workers that test them, which are never more
    // than the mutants.
    func test_theBaselinesLog_namesTheWorkersThatTestTheMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        var baselineLogs: [MutationTestLog] = []
        whenSent(.newTestLogAvailable) { event in
            if let log = event.object as? MutationTestLog, log.mutationPoint == nil {
                baselineLogs.append(log)
            }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(baselineLogs.map(\.workers), [2])
        XCTAssertEqual(baselineLogs.map(\.remainingMutationPointsCount), [2])
    }

    // A mutant's run skips the build, so the first estimate is better based on the timed test run than the baseline.
    func test_theBaselinesLog_carriesTheTimedTestRunsSeconds() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        timeTheTestRun(seconds: 12)
        var baselineLogs: [MutationTestLog] = []
        whenSent(.newTestLogAvailable) { event in
            if let log = event.object as? MutationTestLog, log.mutationPoint == nil {
                baselineLogs.append(log)
            }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(baselineLogs.map(\.testRunSeconds), [12])
    }

    // The clone is copied after the mutated project was built. Its tests must run from binaries built
    // in the clone, or every path compiled into them, `#filePath` included, still points into the
    // mutated project, and tests that write files next to their sources share them across workers.
    func test_eachWorkerCloneIsBuiltBeforeAnyMutantRunsInIt() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.prefix(3), [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "benchmarkTests(using:savingResultsIntoFileNamed:workingDirectory:)",
            timedRun,
        ])
        XCTAssertEqual(ioDelegate.testLogs.prefix(3), ["baseline run", "baseline run worker 1", "timed test run"])
    }
}
