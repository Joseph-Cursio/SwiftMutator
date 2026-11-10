@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingParallelTests {
    func test_aWorkerCloneWhoseBaselineFails_stopsTheRun() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: workerClone.path, log: "testLog")
            )
        )

        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertEqual(removedClones, [[workerClone]])
        XCTAssertEqual(try resultsFiles.kinds(), [], "the clones come before the results, as the baseline does")
    }

    func test_whenCancelled_noFurtherMutantStarts_andNothingMoreIsRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...6).map { try makeSchemataMapping(line: $0) }
        // The baseline, the worker clone's build, then every mutant, in case cancelling doesn't stop them.
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 6)
        let recorded = cancelMutationTesting(whenSent: .newMutationTestOutcomeAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(recorded(), 1)
        // The two that started together, and no other.
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 2)
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // The run under way returns as if it had exited by itself, as a process killed before its run's cancellation
    // handler is in place does.
    func test_whenCancelledWithNoMutantLeftToStart_theRunUnderWayIsNotRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        let recorded = cancelMutationTesting(whenSent: .newMutationTestOutcomeAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(recorded(), 1)
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // Each clone costs a copy and about one baseline build, which a stopped run would only throw away. With no run
    // under way to return, mutation testing would also end as if every mutant had been tested.
    func test_whenCancelledBeforeTheFirstMutant_noWorkerIsCloned() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        // Saying how many workers there are is the last thing before the worker clones are made.
        _ = cancelMutationTesting(whenSent: .workersChosen)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(removedClones, [])
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
    }

    // Stopping the run kills the clones' builds, which then fail. That says nothing about the clones.
    func test_aCancelledWorkerBuild_throwsCancellation_notWorkerBaselineTestFailed() async throws {
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
        XCTAssertFalse(ioDelegate.methodCalls.contains { $0.hasPrefix("runTestSuite") })
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // Stopping the run kills a `cp` under way, which then fails. That says nothing about cloning the project.
    func test_aCloneThatFailsOnceCancelled_throwsCancellation() async throws {
        let testing = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw PerformMutationTesting.WorkerDirectoryError(clone: workerClone, status: SIGKILL)
            },
            removeWorkerDirectories: { _ in }
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed]

        let result = await testing.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [])
    }

    // A worker's run can finish before one that started earlier, and each outcome is kept as it is recorded, so what
    // a stopped run tested is sorted back into the mutants' order for its partial report.
    func test_anInterruptedRun_postsWhatItRecorded_inJobOrder() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...6).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 6)
        // The first run to start returns once the third mutant is recorded, and the fourth run to start once the
        // first is, so the first run's mutant is recorded third, after the third mutant. Mutation testing is
        // cancelled then. The waits are bounded, so the test can't hang.
        let thirdMutantRecorded = DispatchSemaphore(value: 0)
        let firstRunRecorded = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = thirdMutantRecorded.wait(timeout: .now() + 5) }
            if number == 3 { _ = firstRunRecorded.wait(timeout: .now() + 5) }
        }
        var recordedLines: [Int] = []
        whenSent(.newMutationTestOutcomeAvailable) { event in
            guard let mutation = event.object as? MutationTestOutcome.Mutation else { return }
            recordedLines.append(mutation.point.position.line)
            if recordedLines.count == 2 { thirdMutantRecorded.signal() }
            if recordedLines.count == 3 {
                withUnsafeCurrentTask { $0?.cancel() }
                firstRunRecorded.signal()
            }
        }
        var earlyEnds: [EarlyEnd] = []
        whenSent(.mutationTestingEndedEarly) { event in
            (event.object as? EarlyEnd).map { earlyEnds.append($0) }
        }

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(recordedLines.count, 3)
        XCTAssertNotEqual(recordedLines, recordedLines.sorted(), "the runs weren't recorded out of job order")
        XCTAssertEqual(earlyEnds.count, 1)
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnd.reason, .interrupted)
        XCTAssertEqual(earlyEnd.discovered, 6)
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.point.position.line), recordedLines.sorted())
    }
}
