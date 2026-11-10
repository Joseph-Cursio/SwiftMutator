@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingTests {
    // A cancelled run's process was killed, so its outcome, a build error, says nothing about its mutant. Recorded,
    // it would report a mutant that doesn't compile, and five in a row would abort the run as broken.
    func test_whenCancelledDuringAMutantRun_itThrowsCancellation_andRecordsNothingMore() async throws {
        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 3)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .buildError, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let sent = recordEvents(named: [.newMutationTestOutcomeAvailable])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 2)
    }

    // A process killed before its run's cancellation handler is in place reads as one that exited by a signal:
    // a runtime error, which counts as killed. A run that returns once mutation testing is cancelled tested
    // nothing, whatever it says.
    func test_aRunThatReturnsAfterCancellation_isNotRecorded_whateverItsEnding() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .runtimeError, .failed]
        ioDelegate.mutantRunEndings = [.exited]
        ioDelegate.whileRunningMutant = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let sent = recordEvents(named: [.newMutationTestOutcomeAvailable, .newTestLogAvailable])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // Only the baseline's log.
        XCTAssertEqual(sent().map(\.name), [.newTestLogAvailable])
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 1)
    }

    // One at a time, the mutants start just before the first one's run.
    func test_theMutantRunsStart_beforeTheFirstMutantsRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        var mutantRunsAtTheStart: [Int] = []
        let observer = runEvents.observe(.mutantRunsStarted) { [ioDelegate] _ in
            mutantRunsAtTheStart.append(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count)
        }
        defer { observer.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(mutantRunsAtTheStart, [0])
    }

    // Stopping the run kills the baseline run, which then fails. That says nothing about the project's tests, so the
    // run stops without saying they failed, and writes no results file. Its partial output stays where it ran, under no
    // name that looks kept.
    func test_aCancelledBaseline_throwsCancellation_andKeepsNoBaselineLog() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.buildError]
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 0 { withUnsafeCurrentTask { $0?.cancel() } }
        }

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(fileManager.createdFiles.keys.sorted(), [])
        XCTAssertEqual(ioDelegate.keptOutputs.count, 0)
        XCTAssertEqual(resultsFiles.directories, [])
    }

    // The timed test run comes after the baseline but before the results start, so a stop during it, like one during
    // the baseline, has nothing to report: no early end, no results file, and no baseline log to start the progress
    // bar.
    func test_aStopDuringTheTimedTestRun_postsNoEarlyEnd_andStartsNoResults() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        // Stopping the run kills the timed run, which then fails.
        ioDelegate.timedTestRunOutcome = .buildError
        ioDelegate.whileRunningTestsWithoutBuilding = { withUnsafeCurrentTask { $0?.cancel() } }
        let sent = recordEvents(named: [.mutationTestingEndedEarly, .newTestLogAvailable])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(sent().map(\.name), [])
        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 0)
        // The baseline's log was kept as it ended; the stopped timed run's output stays where it ran.
        XCTAssertEqual(fileManager.createdFiles.keys.sorted(), ["/logs/baseline run.log"])
        XCTAssertEqual(ioDelegate.keptOutputs.map(\.output), ["/logs/running/baseline run"])
    }

    func test_whenCancelledBeforeTheFirstMutant_noneRuns() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        // The baseline's log is the last thing sent before the first mutant.
        cancelMutationTesting(whenSent: .newTestLogAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(ioDelegate.methodCalls, ["benchmarkTests(using:savingResultsIntoFileNamed:)"])
    }

    // One worker tests every mutant in the mutated project itself, which the next run's clean-up removes.
    func test_aSerialRun_removesNoClones() async throws {
        var removedClones: [[URL]] = []
        let testing = PerformMutationTesting(
            makeWorkerDirectories: { _, _ in
                XCTFail("a serial run clones nothing")
                return []
            },
            removeWorkerDirectories: { removedClones.append($0) }
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await testing.run(with: state)

        XCTAssertEqual(removedClones, [])
    }
}
