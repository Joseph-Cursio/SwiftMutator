@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingActivationTests {
    // MARK: - Kills that didn't run their code

    // A flaky test, say: with the mutant's block not run, its tests pass this time.
    func test_aKillWhoseBlockDidntRun_isTestedAgain_andWhatThatShowsStands() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .passed]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .didNotRun]
        let sent = recordEvents(named: [.newMutationTestOutcomeAvailable, .unprovenRunsRerunStarted, .unprovenRunRerun])

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.noCoverage, .passed])
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.last?.key, records.first?.key)
        XCTAssertEqual(
            records.last?.rerun,
            MutantResult.Rerun(because: MutantResult.Rerun.codeNotShownRunning, workers: 1)
        )
        XCTAssertEqual(records.last?.log, records.last.map { MutationTestLog.rerunFileName(for: $0.key) })
        // The progress counts each mutant once.
        XCTAssertEqual(sent().filter { $0.name == .newMutationTestOutcomeAvailable }.count, 2)
        XCTAssertEqual(sent().filter { $0.name == .unprovenRunRerun }.count, 1)
    }

    func test_aKillThatRunsItsCodeWhenTestedAgain_isAKill_withNoWarning() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .ran]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [.ran, .ran])
        XCTAssertNil(outcome.unprovenKillWarning)
    }

    func test_aFirstRunThatSurvivesWhenTestedAgain_withItsCodeRunning_isASurvivor() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .runtimeError, .passed, .passed]
        ioDelegate.mutantActivations = [.unknown, .ran, .ran]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [.ran, .ran])
    }

    // Its tests fail whatever the mutant, so the kill stands, as the score has no other verdict for it, and the run
    // says so, with the log to show it.
    func test_aKillThatStillDoesntRunItsCode_standsWithAWarning() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .unknown]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [.didNotRun, .ran])
        XCTAssertTrue(try XCTUnwrap(outcome.unprovenKillWarning).hasPrefix("1 kill's code never ran"))
        let log = try resultsFiles.records(MutantResult.self).last?.log
        XCTAssertNotNil(log, "the log is what the warning has to show")
    }

    // Under `swift test`'s stop at the first failed test, a real kill's marker is there before its failure.
    func test_aKillThatRanItsCode_isntTestedAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .runtimeError]
        ioDelegate.mutantActivations = [.ran, .ran]

        _ = try await run()

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 2)
    }

    // A mutant's verdict from `--mutant` is already out, and its log shows what happened.
    func test_oneMutantsRun_isntTestedAgain() async throws {
        state.selectedMutant = MutantKey(
            path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 1, column: 5, occurrence: 0
        )
        state.mutationMapping = try [makeMapping(lines: [1])]
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        ioDelegate.mutantActivations = [.didNotRun]

        _ = try await run()

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 1)
    }

    // MARK: - Timeouts

    // One worker has tested no timeout again, so this is its one chance to be.
    func test_oneWorkersTimeoutThatDidntRunItsCode_isTestedAgain_butOneThatDid_isnt() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .timeout, .passed]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .didNotRun]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.noCoverage, .timeout])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 3)
    }

    // More than one worker tests every timeout again, once, and whichever run showed the block ran stands.
    func test_workersTestATimeoutAgainOnce_andAKeepsThatItsCodeRan() async throws {
        state.muterConfiguration = swiftTest(workers: 2)
        // The baseline, the clone's build, the two mutants, then the timeouts' reruns.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .timeout, .timeout, .passed, .passed]
        ioDelegate.mutantActivations = [.ran, .didNotRun, .unknown, .unknown]

        let outcome = try await run()

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 4, "each timeout again, and only once")
        XCTAssertEqual(outcome.mutations.filter { $0.activated == .ran }.map(\.testSuiteOutcome), [.passed])
        // The session shows runs can say, so a rerun that says nothing didn't reach mutated code.
        XCTAssertEqual(outcome.mutations.filter { $0.activated == .didNotRun }.map(\.testSuiteOutcome), [.noCoverage])
    }

    // It failed without showing its code ran, as any other such kill has, so it is tested again, as one would be on
    // one worker, and what that shows stands.
    func test_workersTimeoutThatTurnsIntoAKillWithoutItsCode_isTestedAgainToo() async throws {
        state.muterConfiguration = swiftTest(workers: 2)
        state.mutationMapping = try [makeMapping(lines: [1, 2])]
        // The baseline, the clone's build, the two mutants, the timeout's rerun, then the kill's.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .timeout, .passed, .runtimeError, .passed]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .unknown, .didNotRun]

        let outcome = try await run()

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.compactMap(\.rerun?.because), ["timeout", "codeNotShownRunning"])
        XCTAssertEqual(Set(outcome.mutations.map(\.testSuiteOutcome)), [.noCoverage, .passed])
    }

    // MARK: - The rerun on several workers

    // The first of the pool, one at a time, after the first runs.
    func test_workersTestAKillAgainOnTheFirstWorker() async throws {
        state.muterConfiguration = swiftTest(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .passed]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .didNotRun]

        let outcome = try await run()

        XCTAssertEqual(ioDelegate.workingDirectories.last, state.mutatedProjectDirectoryURL)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 3)
        XCTAssertEqual(Set(outcome.mutations.map(\.testSuiteOutcome)), [.noCoverage, .passed])
    }

    // A rerun that times out is what it comes to, and its line says it was run again, so a resume keeps it.
    func test_aKillThatTimesOutWhenTestedAgain_isATimeout_thatAResumeKeeps() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .timeout]
        ioDelegate.mutantActivations = [.didNotRun, .ran, .ran]
        ioDelegate.mutantRunEndings = [.exited, .exited, .timedOut]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.timeout, .passed])
        XCTAssertEqual(try planFromTheLines().toRun, [])
    }

    // MARK: - Stopping and resuming

    // The first runs' lines stay, and no rerun's is written, so a resume tests those kills again.
    func test_aStopBeforeTheRerun_leavesTheKillForAResumeToTestAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .runtimeError, .passed, .passed]
        ioDelegate.mutantActivations = [.didNotRun, .unknown, .ran, .ran]
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        let observer = runEvents.observe(.unprovenRunsRerunStarted) { _ in mutationTesting.cancel() }
        addTeardownBlock { observer.cancel() }

        let result = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.rerun), [nil, nil])
        // The one whose run reached mutated code, and the one that showed nothing, in a session whose runs can say.
        XCTAssertEqual(try planFromTheLines().retestedBecause, [.codeNotShownRunning: 2])
    }

    // MARK: - With property tests

    // After the rerun, so a kill it settles can be one, and one it overturns isn't.
    func test_propertyRerunsFollow_andLeaveOutAKillThatStillDoesntRunItsCode() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            testSuiteTimeOut: 42,
            mutationTestWorkers: 1,
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"]
        )
        let sum = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
        // Two kills without their code, then the first runs it, failing, and the second doesn't.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [sum, sum, sum, sum, "✔ passed"]
        ioDelegate.mutantActivations = [.didNotRun, .didNotRun, .ran, .unknown, .ran]
        ioDelegate.controlRuns = [(.passed, "✔ Test run with 3 tests in 1 suite passed after 0.4 seconds.")]

        _ = try await run()

        XCTAssertEqual(
            try resultsFiles.kinds(),
            ["header", "mutant", "mutant", "mutant", "mutant", "propertyRerun", "end"]
        )
        XCTAssertEqual(try resultsFiles.records(PropertyRerunResult.self).map(\.line), [1])
    }
}
