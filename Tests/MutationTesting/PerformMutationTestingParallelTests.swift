@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// The default test timeout and parallel workers.
final class PerformMutationTestingParallelTests: MuterTestCase {
    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var clonedCounts: [Int] = []
    private var removedClones: [[URL]] = []

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [unowned self] _, count in
            clonedCounts.append(count)
            return Array(repeating: workerClone, count: count)
        },
        removeWorkerDirectories: { [unowned self] in removedClones.append($0) }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.mutationMapping = try [makeSchemataMapping(line: 1), makeSchemataMapping(line: 2)]
    }

    func test_withoutATimeout_mutantsGetTheMinimumDefault() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        // The spy's baseline returns at once, so the minimum applies.
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumDefaultTimeout, PerformMutationTesting.minimumDefaultTimeout]
        )
    }

    func test_aConfiguredTimeoutIsKept() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [42, 42])
        XCTAssertFalse(ioDelegate.methodCalls.contains(timedRun))
    }

    // A SwiftPM mutant's run skips the build, so its default limit comes from one timed run of that command, with no
    // mutant on: five times it at one worker.
    func test_aSwiftPMRunWithoutATimeout_basesTheDefaultOnATimedTestRun() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0 == timedRun }.count, 1)
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [60, 60])
    }

    // Each worker's tests compete with the others' for the same cores, so each worker beyond the first adds one more.
    func test_eachWorkerBeyondTheFirst_addsATimedTestRunToTheDefault() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.loggingDirectory = "/logs"
        // The baseline, the worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [72, 72])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.testRunSeconds, 12)
        XCTAssertEqual(header.timeoutSeconds, 72)
    }

    // The workers are never more than the mutants to test, and the default counts only those that test them.
    func test_theDefault_countsOnlyTheWorkersThatTestMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [72, 72])
    }

    // The progress bar's rate is measured from when the mutants start: after the worker clones are built, which can
    // take minutes and isn't time spent on mutants, and before any mutant's run.
    func test_theMutantRunsStart_onceTheClonesAreBuilt() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        var atTheStart: [[Int]] = []
        whenSent(.mutantRunsStarted) { [unowned self] _ in
            let mutantRuns = ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count
            atTheStart.append([ioDelegate.builtWorkerDirectories.count, mutantRuns])
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(atTheStart, [[1, 0]])
    }

    func test_aShortTimedTestRun_getsTheMinimum() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        timeTheTestRun(seconds: 1)

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumTestRunTimeout, PerformMutationTesting.minimumTestRunTimeout]
        )
    }

    // A timed run that doesn't pass says nothing about how long a passing one takes: it may have crashed at once.
    // The default then comes from the baseline, as for other build systems.
    func test_whenTheTimedTestRunDoesNotPass_theDefaultComesFromTheBaseline() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.timedTestRunOutcome = .runtimeError
        timeTheTestRun(seconds: 12)

        _ = try await sut.run(with: state)

        // The spy's baseline returns at once, so the minimum applies.
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumDefaultTimeout, PerformMutationTesting.minimumDefaultTimeout]
        )
        XCTAssertNil(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).testRunSeconds)
    }

    // An xcodebuild project's mutants run `test-without-building` from a test run of their own, so a timed run of it
    // isn't made, and the default stays based on the baseline.
    func test_anotherBuildSystem_getsNoTimedTestRun() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertFalse(ioDelegate.methodCalls.contains(timedRun))
    }

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
        XCTAssertFalse(ioDelegate.methodCalls.contains("switchOn(schemata:for:at:)"))
        XCTAssertEqual(
            Set(ioDelegate.workingDirectories),
            [state.mutatedProjectDirectoryURL, workerClone]
        )

        // Outcomes keep the mutants' order, whichever worker finished first.
        guard case let .mutationTestOutcomeGenerated(outcome) = result.first else {
            return XCTFail("Expected an outcome, got \(result)")
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
            return XCTFail("Expected an outcome, got \(result)")
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
            timedRun,
            "benchmarkTests(using:savingResultsIntoFileNamed:workingDirectory:)",
        ])
        XCTAssertEqual(ioDelegate.testLogs.prefix(3), ["baseline run", "timed test run", "baseline run worker 1"])
    }

    // Never in the mutated project or a clone, where a test that lists the package's files, or asks git for untracked
    // ones, would see it.
    func test_everyTestRunWritesItsOutputInTheLogFoldersRunningFolder() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs.count, 5, "\(ioDelegate.testLogs)")
        XCTAssertEqual(
            ioDelegate.testLogs.prefix(3),
            ["/logs/running/baseline run", "/logs/running/timed test run", "/logs/running/baseline run worker 1"]
        )
        XCTAssertEqual(ioDelegate.testLogs.filter { !$0.hasPrefix("/logs/running/") }, [])
    }

    // Their files go once read back, and nothing else keeps their logs. A failed worker baseline's is what says why the
    // run stopped.
    func test_theTimedRunsAndEachWorkerBaselinesLogs_areKeptInTheLogFolder_aFailedOnesToo() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .buildError]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: workerClone.path, log: "testLog")
            )
        )

        XCTAssertEqual(
            fileManager.paths.filter { $0.hasSuffix(".log") },
            ["/logs/timed test run.log", "/logs/baseline run worker 1.log"]
        )
        XCTAssertEqual(fileManager.contents, Data("testLog".utf8), "the worker baseline's log, kept last")
    }

    // Each run's output goes once its log is read back, so a finished run's log folder keeps only its own logs.
    func test_theRunningFolder_isRemovedOnceEmpty() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.contentsOfDirectoryAtPath, ["/logs/running"])
        XCTAssertEqual(fileManager.paths, ["/logs/running"])
    }

    // A stop leaves the output of the runs under way, all there is to say what they were doing.
    func test_theRunningFolder_isKeptWithWhatAStopLeftInIt() async throws {
        state.loggingDirectory = "/logs"
        fileManager.contentsOfDirectoryToReturn = ["Sample.swift_RelationalOperatorReplacement_0_1_0.log"]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.paths, [])
    }

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
        // The baseline's log is the last thing sent before the worker clones are made.
        _ = cancelMutationTesting(whenSent: .newTestLogAvailable)

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
        let sut = PerformMutationTesting(
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

        let result = await sut.runInItsOwnTask(with: state)

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

    func test_withThreeWorkers_everyCloneIsBuilt() async throws {
        let clones = (1...2).map { URL(fileURLWithPath: "/project_mutated_worker\($0)") }
        let sut = PerformMutationTesting(makeWorkerDirectories: { _, _ in clones }, removeWorkerDirectories: { _ in })
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 3
        )
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .failed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(Set(ioDelegate.builtWorkerDirectories), Set(clones))
        XCTAssertEqual(ioDelegate.builtWorkerDirectories.count, 2)
    }

    // Both clone builds fail, in whichever order they finish; the report names the same worker each time.
    func test_whenWorkerClonesFail_theLowestNumberedWorkerIsNamed() async throws {
        let clones = (1...2).map { URL(fileURLWithPath: "/project_mutated_worker\($0)") }
        let sut = PerformMutationTesting(makeWorkerDirectories: { _, _ in clones }, removeWorkerDirectories: { _ in })
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 3
        )
        state.mutationMapping = try (1...3).map { try makeSchemataMapping(line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .buildError, .failed]

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(
                reason: .workerBaselineTestFailed(worker: 1, directory: clones[0].path, log: "testLog")
            )
        )
    }

    // Clang module caches record the path they were built under, so the clone's own build would fail
    // on the ones copied from the mutated project.
    func test_cloningTheMutatedProject_discardsItsModuleCaches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated")
        let files = [
            "Sources/File.swift",
            ".build/debug/kept.o",
            ".build/debug/ModuleCache/Swift.pcm",
            ".build/out/Intermediates.noindex/ModuleCache.noindex/Swift.pcm",
        ]
        for file in files {
            let url = project.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let clones = try await PerformMutationTesting.cloneMutatedProject(project, count: 1)

        XCTAssertEqual(clones.map(\.path), [root.appendingPathComponent("project_mutated_worker1").path])
        let clone = try XCTUnwrap(clones.first)
        let exists = { (directory: URL, path: String) in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path)
        }
        XCTAssertTrue(exists(clone, "Sources/File.swift"))
        XCTAssertTrue(exists(clone, ".build/debug/kept.o"))
        XCTAssertFalse(exists(clone, ".build/debug/ModuleCache"))
        XCTAssertFalse(exists(clone, ".build/out/Intermediates.noindex/ModuleCache.noindex"))
        XCTAssertTrue(files.allSatisfy { exists(project, $0) }, "the mutated project keeps its caches")
    }

    // Nothing else would remove them until a later parallel run replaced them.
    func test_whenCloningTheSecondWorkerFails_theFirstCloneAndTheSecondsPartialCopyAreRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated")
        let source = project.appendingPathComponent("Sources/File.swift")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("let answer = 42".utf8).write(to: source)
        let failingClone = root.appendingPathComponent("project_mutated_worker2")

        do {
            _ = try await PerformMutationTesting.cloneMutatedProject(project, count: 3) { project, clone in
                guard clone.path == failingClone.path else {
                    return try FileManager.default.copyItem(at: project, to: clone)
                }
                // A copy that fails partway through leaves what it had copied.
                try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
                try Data().write(to: clone.appendingPathComponent("partial.o"))
                throw PerformMutationTesting.WorkerDirectoryError(clone: clone, status: 1)
            }
            XCTFail("the clones were made")
        } catch {
            XCTAssertEqual((error as? PerformMutationTesting.WorkerDirectoryError)?.clone.path, failingClone.path)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["project_mutated"])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "let answer = 42", "the project is intact")
    }

    // cp's own message says why, such as a full disk, which its exit status alone doesn't.
    func test_whenCpFails_theCloneFailureSaysWhatCpSaid() async throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let missingProject = root.appendingPathComponent("project_mutated")

        do {
            _ = try await PerformMutationTesting.cloneMutatedProject(missingProject, count: 1)
            XCTFail("a project that doesn't exist was cloned")
        } catch let error as PerformMutationTesting.WorkerDirectoryError {
            XCTAssertEqual(error.status, 1)
            XCTAssertEqual(error.error, "cp: \(missingProject.path): No such file or directory")
            XCTAssertTrue(error.description.hasSuffix("(cp exited 1): cp: \(missingProject.path): No such file or directory."))
        }
        #endif
    }

    func test_removeClones_removesEveryCloneGiven_andTheActiveMutantFileBesideIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project_mutated")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("project_mutated.active-mutant"))
        let clones = try (1...3).map { index in
            let clone = root.appendingPathComponent("project_mutated_worker\(index)")
            let object = clone.appendingPathComponent(".build/debug/File.o")
            try FileManager.default.createDirectory(
                at: object.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("object \(index)".utf8).write(to: object)
            try Data().write(to: root.appendingPathComponent("project_mutated_worker\(index).active-mutant"))
            try FileManager.default.createSymbolicLink(
                at: DirectTestRun.helperLink(forWorkerIn: clone), withDestinationURL: URL(fileURLWithPath: "/bin/sh")
            )
            return clone
        }

        PerformMutationTesting.removeClones(clones)

        // The mutated project's own file goes at the end of the run. The links go, not what they lead to.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            ["project_mutated", "project_mutated.active-mutant"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/bin/sh"))
    }

    // The mutated project is kept after the run, for a look, but not the active-mutant file beside it.
    func test_aSwiftPMRun_removesTheActiveMutantFileBesideTheMutatedProject() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.paths, ["/project_mutated.active-mutant"])
    }

    func test_aStoppedSwiftPMRun_removesTheActiveMutantFileBesideTheMutatedProject() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
        _ = cancelMutationTesting(whenSent: .newMutationTestOutcomeAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(fileManager.paths, ["/project_mutated.active-mutant"])
        XCTAssertEqual(removedClones, [[workerClone]])
    }

    // Only a `swift test` run names its mutant in a file.
    func test_anXcodebuildRun_removesNoActiveMutantFile() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.paths, [])
    }

    func test_xcodebuildProjectsIgnoreWorkers() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], mutationTestWorkers: 4
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(
            ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") },
            Array(repeating: "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)", count: 2)
        )
    }

    /// Runs mutation testing in a task of its own, so a test that cancels it mid-run doesn't cancel itself.
    private func runInItsOwnTask() async -> Result<[MutationTestState.Change], Error> {
        await sut.runInItsOwnTask(with: state)
    }

    /// Cancels mutation testing whenever it sends `name`, from the task that sends it; returns how often it did.
    private func cancelMutationTesting(whenSent name: RunEvent.Name) -> () -> Int {
        var count = 0
        let observer = runEvents.observe(name) { _ in
            count += 1
            withUnsafeCurrentTask { $0?.cancel() }
        }
        addTeardownBlock { observer.cancel() }
        return { count }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    private func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The line of each mutant whose outcome is sent, in the order they're sent, until the test ends.
    private func linesOfSentOutcomes() -> () -> [Int] {
        var lines: [Int] = []
        let observer = runEvents.observe(.newMutationTestOutcomeAvailable) { event in
            if let mutation = event.object as? MutationTestOutcome.Mutation {
                lines.append(mutation.point.position.line)
            }
        }
        addTeardownBlock { observer.cancel() }
        return { lines }
    }

    private let timedRun = "runTestsWithoutBuilding(using:savingResultsIntoFileNamed:)"

    /// Makes the timed test run take `seconds` by the injected clock. Every baseline and mutant run takes time too, so
    /// a limit taken from anything but the timed run alone comes out wrong.
    private func timeTheTestRun(seconds: UInt64) {
        let nanoseconds = Locked<UInt64>(1)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningBaseline = { _ in nanoseconds.change { $0 += 100_000_000_000 } }
        ioDelegate.whileRunningTestsWithoutBuilding = { nanoseconds.change { $0 += seconds * 1_000_000_000 } }
        ioDelegate.whileRunningMutant = { _ in nanoseconds.change { $0 += 7_000_000_000 } }
    }

    private func makeSchemataMapping(line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
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
