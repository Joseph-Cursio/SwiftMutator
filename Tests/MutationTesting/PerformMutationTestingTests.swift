@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

final class PerformMutationTestingTests: MuterTestCase {
    private let state = MutationTestState()

    private let expectedMutationPoint = MutationPoint(
        mutationOperatorId: .ror,
        filePath: "/tmp/project/file.swift",
        position: .firstPosition
    )

    private lazy var sut = PerformMutationTesting()

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")

        state.mutationMapping = try [
            makeSchemataMapping(),
            makeSchemataMapping(),
        ]
    }

    func test_whenBaselinePasses_thenRunMutationTesting() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            // Base line
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            // First mutation
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            // Second mutation
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])

        let expectedTestOutcomes = [
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/project/file.swift",
                    position: .null
                ),
                snapshot: .null,
                originalProjectDirectoryUrl: state.projectDirectoryURL,
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL,
                // The spy's "testLog" shows no failed test, and the baseline's shows none that makes lines unreliable.
                killingTests: .noneNamed
            ),
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/project/file.swift",
                    position: .null
                ),
                snapshot: .null,
                originalProjectDirectoryUrl: state.projectDirectoryURL,
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL,
                killingTests: .noneNamed
            ),
        ]

        XCTAssertEqual(
            result, [
                .mutationTestOutcomeGenerated(
                    MutationTestOutcome(
                        mutations: expectedTestOutcomes,
                        projectPath: "/project",
                        mutatedProjectPath: "/project_mutated"
                    )
                ),
            ]
        )
    }

    // Both mutants are in same-named files at the same place, so only the job's number tells their files apart. Two
    // runs under way at once must never share one: the first to finish removes it.
    func test_createLogFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            ioDelegate.testLogs,
            [
                "baseline run",
                "0_path_RelationalOperatorReplacement_0_0_0.log",
                "1_path_RelationalOperatorReplacement_0_0_0.log",
            ]
        )
    }

    // The progress bar's first estimate of the time left starts from this count. It used to come from state no step
    // sets, so the estimate was always 0 minutes.
    func test_theBaselinesLog_countsTheMutantsToTest() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.newTestLogAvailable])

        _ = try await sut.run(with: state)

        let baselineLog = try XCTUnwrap(sent().first?.object as? MutationTestLog)
        XCTAssertNil(baselineLog.mutationPoint)
        XCTAssertEqual(baselineLog.remainingMutationPointsCount, 2)
    }

    func test_whenBaselineFailsDueToTestingFailure() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(log, _)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            XCTAssertFalse(log.isEmpty)
        }

        XCTAssertEqual(
            ioDelegate.methodCalls,
            ["benchmarkTests(using:savingResultsIntoFileNamed:)", ]
        )
    }

    func test_whenBaselineFailsDueToBuildError() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(log, _)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            XCTAssertFalse(log.isEmpty)
        }

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
        ])
    }

    func test_whenBaselineFailsDueToRuntimeError() async throws {
        ioDelegate.testSuiteOutcomes = [.runtimeError]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(log, _)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            XCTAssertFalse(log.isEmpty)
        }

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
        ])
    }

    func test_whenBaselineFails_thenItsLogIsStillPublishedForWritingToDisk() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError]

        // The baseline's output is the only evidence of why Muter can't start, and nothing else records
        // it — so it has to be published even though the run is about to be aborted.
        let expect = expectation(forEvent: .baselineTestFailed) { event in
            (event.object as? MutationTestLog)?.mutationPoint == nil
        }

        // …and not as `.newTestLogAvailable`, which announces "Determined baseline for mutation
        // testing" and starts the progress bar — neither of which happened.
        let announcedSuccess = expectation(forEvent: .newTestLogAvailable)
        announcedSuccess.isInverted = true

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { _ in }

        await fulfillment(of: [expect, announcedSuccess], timeout: 2)
    }

    func test_whenBaselineFails_thenTheAbortReasonCarriesTheMutatedFilePaths() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError]

        try await assertThrowsMuterError(
            await sut.run(with: state)
        ) { error in
            guard case let .mutationTestingAborted(reason: .baselineTestFailed(_, mutatedFilePaths)) = error else {
                XCTFail("Expected mutationTestingAborted, got \(error)")
                return
            }

            // Naming the files Muter rewrote is what lets the message tell a broken mutant apart from
            // a misconfigured test command.
            XCTAssertEqual(mutatedFilePaths, ["/some/path", "/some/path"])
        }
    }

    func test_whenEncountersFiveConsecutiveBuildErrors_thenCancelMutationTesting() async throws {
        ioDelegate.testSuiteOutcomes = [
            .passed,
            .buildError,
            .buildError,
            .buildError,
            .buildError,
            .buildError,
        ]

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 5)

        try await assertThrowsMuterError(
            await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
    }

    // A `muter.xctestrun` that couldn't be written still switches on the mutant before. The run stops before the
    // mutant's tests run, rather than record that mutant's verdict for this one, and what it tested is reported.
    func test_whenAMutantCannotBeSwitchedOn_thenMutationTestingStops_beforeItsTestsRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let error = CocoaError(.fileWriteOutOfSpace)
        ioDelegate.switchOnError = error
        let sent = recordEvents(named: [.mutationTestingEndedEarly])
        let id = try XCTUnwrap(state.mutationMapping.first?.mutationSchemata.first).id

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .mutantNotSwitchedOn(id: id, description: error.localizedDescription))
        )

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
        ])
        let earlyEnd = try XCTUnwrap(sent().compactMap { $0.object as? EarlyEnd }.first)
        XCTAssertEqual(earlyEnd.reason, .aborted)
        XCTAssertEqual(earlyEnd.detail, "mutantNotSwitchedOn")
        XCTAssertEqual(earlyEnd.outcome.mutations, [])
    }

    // What an abort tested makes the partial report, the build error that ended it included.
    func test_whenTooManyBuildErrorsAbort_whatWasTestedIsPosted_inJobOrder() async throws {
        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 6)
        ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )

        let earlyEnds = sent().compactMap { $0.object as? EarlyEnd }
        XCTAssertEqual(earlyEnds.count, 1)
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnd.reason, .aborted)
        XCTAssertEqual(earlyEnd.detail, "tooManyBuildErrors")
        XCTAssertEqual(earlyEnd.discovered, 6)
        XCTAssertEqual(
            earlyEnd.outcome.mutations.map(\.testSuiteOutcome),
            [.failed] + Array(repeating: .buildError, count: 5)
        )
    }

    // A run that stops after its last mutant's result has every result, so its sample's score has a margin, as
    // `report` of its file gives one. One that stops before it doesn't.
    func test_anEarlyEndsSample_isCutShort_onlyWhenAMutantHasNoResult() async throws {
        let sent = recordEvents(named: [.mutationTestingEndedEarly])
        for mutants in [6, 8] {
            state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: mutants)
            let sample = SampleSelection(size: mutants, seed: 7, mutantsSampledFrom: 20, mutantsSampled: mutants)
            state.apply([.sampleSelected(sample)])
            ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)

            await assertThrowsMuterError(
                try await sut.run(with: state),
                .mutationTestingAborted(reason: .tooManyBuildErrors)
            )
        }

        let earlyEnds = sent().compactMap { $0.object as? EarlyEnd }
        XCTAssertEqual(earlyEnds.map(\.outcome.sampleIsCutShort), [false, true])
    }

    // Nothing was tested, and the abort says why.
    func test_aFailedBaseline_postsNoEarlyEnd() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(sent().count, 0)
    }

    func test_aFinishedRun_postsNoEarlyEnd() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent().count, 0)
    }

    // The jobs and their keys are there before the baseline runs, so only its passing tells a stop that has something
    // to report from one that hasn't. A stop during the baseline sends no early end; one just after it passed sends
    // one, with nothing tested yet and every mutant discovered.
    func test_anEarlyEnd_isPostedOnlyOnceTheBaselinePassed() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError, .passed]
        ioDelegate.whileRunningBaseline = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        let stoppedDuringTheBaseline = await runInItsOwnTask()

        XCTAssertThrowsError(try stoppedDuringTheBaseline.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(sent().count, 0)

        ioDelegate.whileRunningBaseline = nil
        // The baseline's log is the last thing sent before the first mutant.
        cancelMutationTesting(whenSent: .newTestLogAvailable)

        let stoppedOnceItPassed = await runInItsOwnTask()

        XCTAssertThrowsError(try stoppedOnceItPassed.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let earlyEnds = sent().compactMap { $0.object as? EarlyEnd }
        XCTAssertEqual(earlyEnds.count, 1)
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnd.reason, .interrupted)
        XCTAssertEqual(earlyEnd.discovered, 2)
        XCTAssertEqual(earlyEnd.outcome.mutations.count, 0)
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 0)
    }

    func test_whenEncountersFiveNonConsecutiveBuildErrors_thenPerformMutationTesting() async throws {
        ioDelegate.testSuiteOutcomes = [
            .passed,
            .buildError,
            .buildError,
            .buildError,
            .buildError,
            .failed,
            .passed,
        ]

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 5)

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            // base line
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            // First operator
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])

        let expectedBuildErrorOutcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .buildError,
            point: MutationPoint(
                mutationOperatorId: .ror,
                filePath: "/tmp/project/file.swift",
                position: .firstPosition
            ),
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project")
        )

        let expectedFailingOutcome = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            point: MutationPoint(
                mutationOperatorId: .ror,
                filePath: "/tmp/project/file.swift",
                position: .firstPosition
            ),
            snapshot: .null,
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project"),
            killingTests: .noneNamed
        )

        let expectedTestOutcomes = Array(repeating: expectedBuildErrorOutcome, count: 4) + [expectedFailingOutcome]

        XCTAssertEqual(result, [
            .mutationTestOutcomeGenerated(
                MutationTestOutcome(
                    mutations: expectedTestOutcomes,
                    projectPath: "/project",
                    mutatedProjectPath: "/project_mutated"
                )
            ),
        ])
    }

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
        let observer = runEvents.observe(.mutantRunsStarted) { [unowned self] _ in
            mutantRunsAtTheStart.append(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count)
        }
        defer { observer.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(mutantRunsAtTheStart, [0])
    }

    // Stopping the run kills the baseline run, which then fails. That says nothing about the project's tests, so the
    // run stops without saying they failed, and writes no results file.
    func test_aCancelledBaseline_throwsCancellation_andPostsNoBaselineFailure() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.buildError]
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 0 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let sent = recordEvents(named: [.baselineTestFailed])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(sent().count, 0)
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
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { _, _ in
                XCTFail("a serial run clones nothing")
                return []
            },
            removeWorkerDirectories: { removedClones.append($0) }
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(removedClones, [])
    }

    func test_whenThePassingBaselinePrintsAFailureLikeLine_thenMutantsRunWithStoppingOff() async throws {
        let lookalike = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 1 == 2"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: true
        )
        // A test of a test reporter that prints a sample of its output, and passes.
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        \(lookalike)
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false])
        let notices = sent().filter { $0.name == .stopAtFirstFailureTurnedOff }
        XCTAssertEqual(notices.count, 1)
        let reason = try XCTUnwrap(notices.first?.object as? String)
        XCTAssertTrue(reason.hasSuffix("\n  \(lookalike)"), reason)
        // Before the baseline's log, which starts the progress bar.
        XCTAssertEqual(sent().first?.name, .stopAtFirstFailureTurnedOff)
    }

    // A run also stops at a crash's line, so one a passing baseline prints turns stopping off too.
    func test_whenThePassingBaselinePrintsACrashLikeLine_thenMutantsRunWithStoppingOff() async throws {
        let lookalike = "error: Process '/p/Tests.xctest' exited with unexpected signal code 5"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: true
        )
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        \(lookalike)
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
        let reason = try XCTUnwrap(sent().first?.object as? String)
        XCTAssertTrue(reason.hasSuffix("looks like a failed test or a crash:\n  \(lookalike)"), reason)
    }

    // The line would also count a mutant whose run reaches the time limit after printing it as killed.
    func test_whenThePassingBaselinePrintsAFailureLikeLineWithoutStopping_thenItStillDoesNotCount() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: false
        )
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        ✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 1 == 2
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false])
        // Runs weren't going to stop at a failed test, so nothing changed that is worth a notice.
        XCTAssertEqual(sent().count, 0)
    }

    // With the key unset: stopping at the first failed test is the default.
    func test_whenThePassingBaselineHasNoFailureLikeLine_thenMutantsStopAtTheirFirstFailure() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        ✔ Test sum() passed after 0.001 seconds.
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [true, true])
        XCTAssertEqual(sent().count, 0)
    }

    func test_whenStopAtFirstFailureIsSetForXcodebuild_thenANoticeSaysItIsOff() async throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], stopAtFirstFailure: true
        )
        state.muterConfiguration = configuration
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(
            named: [.mutationTestingStarted, .stopAtFirstFailureTurnedOff, .newTestLogAvailable]
        )

        _ = try await sut.run(with: state)

        let names = sent().map(\.name)
        XCTAssertEqual(names.filter { $0 == .stopAtFirstFailureTurnedOff }.count, 1)
        // With the start of mutation testing, before the baseline's log starts the progress bar.
        XCTAssertEqual(
            Array(names.prefix(3)),
            [.mutationTestingStarted, .stopAtFirstFailureTurnedOff, .newTestLogAvailable]
        )
        let reason = try XCTUnwrap(configuration.stopAtFirstFailureUnsupportedReason)
        let notice = sent().first { $0.name == .stopAtFirstFailureTurnedOff }
        XCTAssertEqual(notice?.object as? String, reason)
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
    }

    // Rather than in a new folder of ~/Library/Developer/Xcode/DerivedData for each run. The folder goes with the run.
    func test_xcodebuildMutantsRuns_keepTheirDerivedDataBesideTheCopy_untilTheRunEnds() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.apply([.testDiagnosticsOptionChecked(canBeTurnedOff: true)])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), [worker, worker])
        XCTAssertEqual(fileManager.paths.filter { $0.hasSuffix(".DerivedData") }, ["/project_mutated.DerivedData"])
    }

    // Only an xcodebuild that lists the option in its `-help` gets it (see BuildForTesting).
    func test_xcodebuildMutantsRuns_keepTestDiagnostics_unlessTheTestCommandTakesTheOption() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map { $0.xcodeWorker?.testDiagnosticsOff }, [false, false])
    }

    // Before the baseline: a booted simulator an earlier run left holds memory the baseline could use.
    func test_anXcodebuildRun_sweepsLeftoverWorkerSimulators_beforeTheBaseline() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.failed]

        try await assertThrowsMuterError(await sut.run(with: state)) { _ in }

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
    }

    func test_aSwiftPMRun_leavesSimulatorsAlone() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [])
    }

    func test_swiftPMMutantsRuns_haveNoXcodeWorker() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), [nil, nil])
        XCTAssertFalse(fileManager.paths.contains { $0.hasSuffix(".DerivedData") })
    }

    // A real run that found the simulator still busy with the run before. It tested nothing, so the mutant runs again
    // on the same simulator, still switched on, and only that run is recorded and counted. The first run's log is kept.
    func test_whenTheSimulatorFailsToLaunchARun_itRunsOnceMore_andOnlyThatRunIsRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [launchFailed, "the second run's log", "testLog"]
        let sent = recordEvents(named: [.runRepeatedAfterLaunchFailure, .newTestLogAvailable])

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestsWithoutBuilding(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
        XCTAssertEqual(outcomes(in: result), [.passed, .failed])
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.outcome), [.passed, .failed])
        XCTAssertEqual(sent().map(\.name), [
            .newTestLogAvailable, // the baseline's
            .runRepeatedAfterLaunchFailure,
            .newTestLogAvailable,
            .newTestLogAvailable,
        ])
        let repeated = try XCTUnwrap(sent().compactMap { $0.object as? RepeatedRun }.first)
        XCTAssertEqual(repeated.worker, 0)
        XCTAssertEqual(repeated.mutant.testSuiteOutcome, .passed)
        XCTAssertEqual(repeated.line, "Simulator device failed to launch com.example.MacCloud-client-iOS.")
        XCTAssertEqual(repeated.log.testLog, launchFailed)
        XCTAssertEqual(repeated.log.keptFileName, MutationTestLog.launchFailedFileName(for: records[0].log))
        let logs = sent().compactMap { $0.object as? MutationTestLog }.map(\.testLog)
        XCTAssertEqual(logs.dropFirst(), ["the second run's log", "testLog"])
    }

    // A real baseline that found Xcode's clone of the simulator busy. It tested nothing, so it runs once more, and
    // mutation testing goes on from that run. The first run's log is kept beside the baseline's.
    func test_whenTheSimulatorFailsToLaunchTheBaseline_itRunsOnceMore_andTestingGoesOn() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.testSuiteOutcomes = [.failed, .passed, .failed, .failed]
        ioDelegate.baselineTestLogs = [launchFailed, "the second baseline's log"]
        let sent = recordEvents(named: [.baselineRepeatedAfterLaunchFailure, .newTestLogAvailable])

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count, 2)
        XCTAssertEqual(outcomes(in: result), [.failed, .failed])
        XCTAssertEqual(sent().map(\.name), [
            .baselineRepeatedAfterLaunchFailure,
            .newTestLogAvailable, // the second baseline's
            .newTestLogAvailable,
            .newTestLogAvailable,
        ])
        let (line, log) = try XCTUnwrap(sent().first?.object as? (String, MutationTestLog))
        XCTAssertEqual(line, "Simulator device failed to launch com.example.MacCloud-client-iOS.")
        XCTAssertEqual(log.testLog, launchFailed)
        XCTAssertNil(log.mutationPoint)
        XCTAssertEqual(log.keptFileName, "baseline run (launch failed).log")
        let baselineLog = try XCTUnwrap(sent()[1].object as? MutationTestLog)
        XCTAssertEqual(baselineLog.testLog, "the second baseline's log")
    }

    // One more baseline at most, which fails mutation testing as any failed baseline does. A SwiftPM baseline has no
    // simulator, so its failure is never run again.
    func test_aBaselineTheSimulatorFailsToLaunchTwice_andASwiftPMBaseline_failAsAnyFailedBaselineDoes() async throws {
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        let sent = recordEvents(named: [.baselineRepeatedAfterLaunchFailure])
        for (executable, baselines) in [("/usr/bin/xcodebuild", 2), ("/usr/bin/swift", 1)] {
            state.muterConfiguration = MuterConfiguration(executable: executable, arguments: ["test"])
            let baselinesBefore = ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count
            ioDelegate.testSuiteOutcomes = [.failed, .failed]
            ioDelegate.baselineTestLogs = [launchFailed, launchFailed]

            try await assertThrowsMuterError(await sut.run(with: state)) { error in
                guard case .mutationTestingAborted(reason: .baselineTestFailed) = error else {
                    return XCTFail("Expected mutationTestingAborted, got \(error)")
                }
            }

            let baselinesRun = ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count - baselinesBefore
            XCTAssertEqual(baselinesRun, baselines, executable)
        }
        XCTAssertEqual(sent().count, 1)
    }

    // The second run's line is on disk before the console says the mutant ran again or keeps the first run's log, so a
    // stop at once after that never leaves a mutant said to have run again with no line.
    func test_aRunTheSimulatorFailedToLaunch_isSentOnlyOnceTheSecondRunsResultIsWritten() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/launch_preflightBusy.log")]
        var recordedWhenSent: [[TestSuiteOutcome]] = []
        let observer = runEvents.observe(.runRepeatedAfterLaunchFailure) { [resultsFiles] _ in
            recordedWhenSent.append((try? resultsFiles.records(MutantResult.self).map(\.outcome)) ?? [])
        }
        addTeardownBlock { observer.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(recordedWhenSent, [[.passed]])
    }

    // One more run at most: a mutant that crashes its app at launch would otherwise run for ever. That run counts,
    // whatever it comes to.
    func test_whenTheSimulatorFailsToLaunchARunTwice_theSecondIsRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let launchFailed = loadFixture("SimulatorTrouble/launch_beforeEstablishingConnection.log")
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed]
        ioDelegate.mutantTestLogs = [launchFailed, launchFailed]
        let sent = recordEvents(named: [.runRepeatedAfterLaunchFailure])

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 3)
        XCTAssertEqual(outcomes(in: result), [.failed, .failed])
        XCTAssertEqual(sent().count, 1)
    }

    // A run that passed tested its mutant, whatever its log says; another build system's run has no simulator.
    func test_aPassedRun_andASwiftPMRun_neverRunAgain() async throws {
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        let sent = recordEvents(named: [.runRepeatedAfterLaunchFailure])
        let runs: [(executable: String, outcomes: [TestSuiteOutcome])] = [
            ("/usr/bin/xcodebuild", [.passed, .passed]),
            ("/usr/bin/swift", [.failed, .failed]),
        ]
        for (executable, recorded) in runs {
            state.muterConfiguration = MuterConfiguration(executable: executable, arguments: ["test"])
            ioDelegate.testSuiteOutcomes = [.passed] + recorded
            ioDelegate.mutantTestLogs = [launchFailed, launchFailed]

            let result = try await sut.run(with: state)

            XCTAssertEqual(outcomes(in: result), recorded, executable)
        }
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 4)
        XCTAssertEqual(sent().count, 0)
    }

    // A real run on a simulator deleted before it. Every run on it would fail the same way without a test, and count as
    // a kill, so mutation testing stops without recording it, keeps its log, and keeps what it recorded before.
    func test_whenARunsSimulatorIsGone_mutationTestingStops_withoutRecordingTheRun() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        let gone = loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .buildError]
        ioDelegate.mutantTestLogs = ["testLog", gone]
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        do {
            _ = try await sut.run(with: state)
            XCTFail("expected an abort")
        } catch let MuterError.mutationTestingAborted(reason: .simulatorUnavailable(worker, line, log)) {
            XCTAssertEqual(worker, 0)
            XCTAssertEqual(
                line, "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
            )
            let kept = try XCTUnwrap(log)
            XCTAssertTrue(kept.hasPrefix("/logs/") && kept.hasSuffix(" (simulator gone).log"), kept)
            XCTAssertEqual(fileManager.createdFiles[kept], Data(gone.utf8))
        }

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 2, "no run again")
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.outcome), [.failed])
        let earlyEnd = try XCTUnwrap(sent().compactMap { $0.object as? EarlyEnd }.first)
        XCTAssertEqual(earlyEnd.detail, "simulatorUnavailable(worker: 0)")
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.testSuiteOutcome), [.failed])
    }

    func test_whenStopAtFirstFailureIsSetWithRepeatUntil_thenANoticeSaysItIsOff() async throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--repeat-until", "pass"],
            stopAtFirstFailure: true
        )
        state.muterConfiguration = configuration
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent().count, 1)
        let reason = try XCTUnwrap(sent().first?.object as? String)
        XCTAssertEqual(reason, configuration.stopAtFirstFailureUnsupportedReason)
        XCTAssertTrue(reason.contains("--repeat-until"), reason)
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
    }

    func test_whenStopAtFirstFailureIsUnset_thenNoNoticeIsSent() async throws {
        let sent = recordEvents(named: [.stopAtFirstFailureTurnedOff])

        // Only an explicit `true` asks for it, so a test command that can't use it is worth a notice only then.
        for stopAtFirstFailure in [nil, false] as [Bool?] {
            state.muterConfiguration = MuterConfiguration(
                executable: "/usr/bin/xcodebuild", arguments: ["test"], stopAtFirstFailure: stopAtFirstFailure
            )
            ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(sent().count, 0)
    }

    // The baseline still builds the project, and makes a kill mean something. Neither the run of the bundles without
    // `swift test` nor a timed run would save more than it costs for one mutant, whose tests all run, so its log names
    // every one that fails. The active-mutant file goes, so the kept copy is left with the mutant off.
    func test_aOneMutantRun_runsTheBaselineAndOneJob_withoutTheProbeOrTimedRun_withStoppingOff() async throws {
        let key = MutantKey(
            path: "/tmp/project/file.swift", mutationOperatorId: .ror, line: 0, column: 0, occurrence: 0
        )
        state.mutationMapping = try [makeSchemataMapping()]
        state.apply([.mutantSelected(key)])
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], stopAtFirstFailure: true
        )
        state.loggingDirectory = "/logs"
        current.directTestRun = { _, _ in
            XCTFail("one mutant's run doesn't try the bundles without swift test")
            return .failure(.init(reason: nil))
        }
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(fileManager.paths.filter { $0.hasSuffix(".active-mutant") }, ["/project_mutated.active-mutant"])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.mutant, key.description)
        XCTAssertNil(header.testRunSeconds)
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumDefaultTimeout)
        XCTAssertFalse(header.stopsAtFirstFailure)
        XCTAssertEqual(header.workers, 1)
        // As loaded, which is what a resume compares.
        XCTAssertEqual(header.configuration.stopAtFirstFailure, true)
        let outcome = try XCTUnwrap(finished().first?.object as? MutationTestOutcome)
        XCTAssertEqual(outcome.mutant, key.description)
    }

    // What the end of a run of one mutant prints of it, sent once its line is written: its change, read from the
    // original file and never the copy, its log, its verdict, and what runs its tests with it on.
    func test_aOneMutantRun_sendsWhatItFound_withItsChangeFromTheOriginalFile() async throws {
        let key = try selectOneTernary()
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        ioDelegate.mutantTestLogs = ["Test run with 3 tests passed.\n"]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        XCTAssertEqual(fileManager.contentsAtPath, ["/project/Sources/Bar.swift"])
        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(run.key, key)
        XCTAssertEqual(run.switchID, state.mutationMapping.first?.mutationSchemata.first?.id)
        XCTAssertEqual(run.change, ["-2:     return flag ? 1 : 2", "+2:     return flag ? 2 : 1"])
        XCTAssertEqual(run.outcome, .passed)
        XCTAssertNil(run.killingTests)
        XCTAssertEqual(run.timeoutSeconds, 60)
        XCTAssertEqual(run.testLog, "Test run with 3 tests passed.\n")
        XCTAssertEqual(run.logPath, "/logs/" + MutationTestLog.keptFileName(for: key))
        XCTAssertEqual(run.mutatedProject, "/project_mutated")
        XCTAssertEqual(run.buildSystem, .swift)
        XCTAssertEqual(run.testCommand, ["/usr/bin/swift", "test"])
    }

    // A test plan's file that changed since the plan was made, let through by --plan-ignoring, may no longer hold the
    // mutant's code at its place, so the change is the one the snapshot gives.
    func test_aOneMutantRun_ofAPlansChangedFile_showsTheChangeAsTheSnapshotGivesIt() async throws {
        try selectOneTernary()
        state.apply([
            .testPlanLoaded(LoadedTestPlan(
                path: "/project/muter-mappings.json",
                sha256: "9e1f",
                formatVersion: TestPlanCoding.formatVersion,
                swiftMutatorVersion: muterCore.version,
                scope: nil,
                sources: ProjectTree(
                    listedBy: .git,
                    files: ["Sources/Bar.swift": "0000"],
                    excluded: [],
                    treeSHA256: ProjectTree.treeHash(of: ["Sources/Bar.swift": "0000"])
                ),
                mutatedFiles: nil,
                linkedFiles: nil,
                mutatedPaths: []
            )),
        ])
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(run.change, ["- flag ? 1 : 2", "+ flag ? 2 : 1"])
    }

    // A plan that doesn't record the project's files, as one in format 0 doesn't, isn't checked against them, so its
    // file may have changed too: the change is the one the snapshot gives.
    func test_aOneMutantRun_ofAPlanThatDoesntRecordItsFile_showsTheChangeAsTheSnapshotGivesIt() async throws {
        try selectOneTernary()
        loadPlan(sources: nil)
        fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        let run = try XCTUnwrap(sent().first?.object as? OneMutantRun)
        XCTAssertEqual(run.change, ["- flag ? 1 : 2", "+ flag ? 2 : 1"])
    }

    // A plan's file as the plan recorded it, here through a symbolic link, by what its link's file held, shows the
    // change from the original file.
    func test_aOneMutantRun_ofAPlansUnchangedFile_showsTheChangeFromTheOriginalFile() async throws {
        let digest = FileDigest.sha256(of: Data(Self.ternarySource.utf8))
        for (sources, linkedFiles) in [
            (["Sources/Bar.swift": digest], nil),
            (["Sources/Bar.swift": ProjectTree.linkPrefix + "0000"], ["Sources/Bar.swift": digest]),
        ] {
            try selectOneTernary()
            loadPlan(sources: sources, linkedFiles: linkedFiles)
            fileManager.fileContentsToReturn = Data(Self.ternarySource.utf8)
            ioDelegate.testSuiteOutcomes = [.passed, .passed]
            let sent = recordEvents(named: [.oneMutantTested])

            _ = try await sut.run(with: state)

            let run = try XCTUnwrap(sent().last?.object as? OneMutantRun)
            XCTAssertEqual(run.change, ["-2:     return flag ? 1 : 2", "+2:     return flag ? 2 : 1"])
        }
    }

    /// Loads a test plan that records the project's `sources`, each file's SHA-256 by its path, or doesn't, as a plan
    /// in format 0 doesn't, and the SHA-256 of each of `linkedFiles`.
    private func loadPlan(sources: [String: String]?, linkedFiles: [String: String]? = nil) {
        state.apply([
            .testPlanLoaded(LoadedTestPlan(
                path: "/project/muter-mappings.json",
                sha256: "9e1f",
                formatVersion: sources == nil ? 0 : TestPlanCoding.formatVersion,
                swiftMutatorVersion: sources == nil ? nil : muterCore.version,
                scope: nil,
                sources: sources.map {
                    ProjectTree(listedBy: .git, files: $0, excluded: [], treeSHA256: ProjectTree.treeHash(of: $0))
                },
                mutatedFiles: nil,
                linkedFiles: linkedFiles,
                mutatedPaths: []
            )),
        ])
    }

    // Only a run of one mutant prints it on its own.
    func test_aWholeRun_sendsNoOneMutantRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let sent = recordEvents(named: [.oneMutantTested])

        _ = try await sut.run(with: state)

        XCTAssertTrue(sent().isEmpty)
        XCTAssertTrue(fileManager.contentsAtPath.isEmpty, "\(fileManager.contentsAtPath)")
    }

    private static let ternarySource = "func pick(_ flag: Bool) -> Int {\n    return flag ? 1 : 2\n}\n"

    /// Makes the state's one mutant a swapped ternary in `Sources/Bar.swift` of the copy, at the end of
    /// `ternarySource`'s line 2, and selects it, as `--mutant` does, under a 60 s limit.
    @discardableResult
    private func selectOneTernary() throws -> MutantKey {
        let path = "/project_mutated/Sources/Bar.swift"
        let schema = try MutationSchema.make(
            filePath: path,
            mutationOperatorId: .swapTernary,
            position: MutationPosition(utf8Offset: 56, line: 2, column: 24),
            snapshot: .make(before: "flag ? 1 : 2", after: "flag ? 2 : 1", description: "swapped ternary operator")
        )
        state.mutationMapping = try [
            SchemataMutationMapping.make(filePath: path, (source: "func bar() { }", schemata: [schema])),
        ]
        let key = MutantKey(
            path: "Sources/Bar.swift", mutationOperatorId: .swapTernary, line: 2, column: 24, occurrence: 0
        )
        state.apply([.mutantSelected(key)])
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 60
        )
        state.loggingDirectory = "/logs"
        return key
    }

    /// The outcome of each mutant the run's result reports, in job order.
    private func outcomes(in result: [MutationTestState.Change]) -> [TestSuiteOutcome] {
        result.flatMap { change -> [TestSuiteOutcome] in
            guard case let .mutationTestOutcomeGenerated(outcome) = change else { return [] }
            return outcome.mutations.map(\.testSuiteOutcome)
        }
    }

    /// Records every event sent with one of `names`, in order, until the test ends.
    private func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        let tokens = names.map { name in
            runEvents.observe(name) { sent.append($0) }
        }
        addTeardownBlock { tokens.forEach { $0.cancel() } }
        return { sent }
    }

    /// Runs mutation testing in a task of its own, so a test that cancels it mid-run doesn't cancel itself.
    private func runInItsOwnTask() async -> Result<[MutationTestState.Change], Error> {
        await sut.runInItsOwnTask(with: state)
    }

    /// Cancels mutation testing when it sends `name`, from the task that sends it.
    private func cancelMutationTesting(whenSent name: RunEvent.Name) {
        let observer = runEvents.observe(name) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        addTeardownBlock { observer.cancel() }
    }

    private func makeSchemataMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: .firstPosition,
                        snapshot: .null
                    ),
                ]
            )
        )
    }
}
