@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingResultsTests {
    func test_aFinishedRun_endsWithAnEndLine_whoseDurationIsTheOutcomes() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let calls = Locked(0.0)
        current.now = {
            calls.change { count in
                count += 1
                return ResultsHeader.fixedStart.addingTimeInterval(count * 2.5)
            }
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "end"])
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.session, 1)
        XCTAssertEqual(end.reason, .finished)
        XCTAssertNil(end.detail)
        XCTAssertEqual(end.recorded, 2)
        XCTAssertGreaterThan(outcome.testDuration, 0)
        XCTAssertEqual(end.testDurationSeconds, outcome.testDuration)
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertGreaterThan(end.endedAt, header.startedAt)
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
    }

    func test_tooManyBuildErrors_writesTheFifth_thenAnAbortedEndLine() async throws {
        state.mutationMapping = try (1...5).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .buildError, count: 5)

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )

        XCTAssertEqual(try resultsFiles.kinds(), ["header"] + Array(repeating: "mutant", count: 5) + ["end"])
        XCTAssertEqual(
            try resultsFiles.records(MutantResult.self).map(\.outcome),
            Array(repeating: .buildError, count: 5)
        )
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .aborted)
        XCTAssertEqual(end.detail, "tooManyBuildErrors")
        XCTAssertEqual(end.recorded, 5)
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
    }

    func test_anInterruptedRun_endsWithAnInterruptedEndLine() async throws {
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .buildError, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "end"])
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertNil(end.detail)
        XCTAssertEqual(end.recorded, 1)
    }

    // It tells a CI cancellation (SIGTERM) apart from a Ctrl-C (SIGINT).
    func test_anInterruptedRun_namesItsSignalInTheEndLine_andTheEarlyEnd() async throws {
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .buildError, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 {
                XCTAssertTrue(current.interruption.record(SIGTERM))
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        var earlyEnds: [EarlyEnd] = []
        whenSent(.mutationTestingEndedEarly) { event in
            if let earlyEnd = event.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(end.detail, "SIGTERM")
        XCTAssertEqual(earlyEnds.map(\.reason), [.interrupted])
        XCTAssertEqual(earlyEnds.map(\.detail), ["SIGTERM"])
    }

    // A second signal, Ctrl-\ or the grace period ends SwiftMutator wherever mutation testing is. Here it goes on, as
    // it can't once SwiftMutator has exited: no line follows the end line.
    func test_stoppingAtOnce_writesAnInterruptedEndLine_countingTheLinesBeforeIt() async throws {
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 {
                XCTAssertTrue(current.interruption.record(SIGINT))
                current.interruption.stoppingAtOnce()
            }
        }
        let unavailable = recordEvents(named: [.resultsFileUnavailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "end"])
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(end.detail, "SIGINT")
        XCTAssertEqual(end.recorded, 1)
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
        XCTAssertEqual(unavailable().count, 0, "a line not written once the session has ended is no failure")
    }

    // Removing the worker clones, after the end line, can take seconds.
    func test_stoppingAtOnce_afterTheEndLine_writesNothing() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)
        current.interruption.stoppingAtOnce()

        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "end"])
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.reason), [.finished])
    }

    // Before the header there's no session in the file to end, as when the baseline is still running.
    func test_stoppingAtOnce_beforeTheHeader_writesNothing() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.whileRunningBaseline = { _ in
            XCTAssertTrue(current.interruption.record(SIGTERM))
            current.interruption.stoppingAtOnce()
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.kinds().filter { $0 == "end" }.count, 1)
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.reason), [.finished])
    }

    // Stopping the run kills the clones' builds, which then fail, but no clone was at fault. The clones come before the
    // results, as the baseline does, so there is nothing yet to end.
    func test_aCancelledWorkerBuild_startsNoResults() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 1 { mutationTesting.cancel() }
        }

        let result = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(try resultsFiles.kinds(), [])
    }

    // Removing large clones can take seconds, and a second signal in that time exits at once, so the end line comes
    // first. A clone left behind is removed when SwiftMutator next runs.
    func test_workerClonesAreRemovedAfterTheEndLine() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        // The baseline, the worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]
        let removals = removingClonesRecordsTheResultsLines()

        _ = try await removals.sut.run(with: state)

        XCTAssertEqual(removals.kindsAtEach(), [["header", "mutant", "mutant", "end"]])
    }

    func test_workerClonesAreRemovedAfterTheEndLine_whenTheRunIsInterrupted() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        let removals = removingClonesRecordsTheResultsLines()
        // Both mutants start at once; the run still under way when the first is recorded is not recorded.
        whenSent(.newMutationTestOutcomeAvailable) { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await removals.sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(removals.kindsAtEach(), [["header", "mutant", "end"]])
    }

    // The end line is on disk before anything is said about what was tested, and that is said before the clones,
    // which can take seconds, are removed.
    func test_theEarlyEndComesAfterTheEndLine_andBeforeClonesAreRemoved() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        var events: [String] = []
        let testing = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
            removeWorkerDirectories: { _ in events.append("clones removed") }
        )
        whenSent(.mutationTestingEndedEarly) { [resultsFiles] _ in
            events.append("early end sent after the \((try? resultsFiles.kinds().last) ?? "no") line")
        }
        whenSent(.newMutationTestOutcomeAvailable) { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await testing.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(events, ["early end sent after the end line", "clones removed"])
    }
}
