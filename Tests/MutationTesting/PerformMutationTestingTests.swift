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
            "switchOn(schemata:for:at:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            // Second mutation
            "switchOn(schemata:for:at:)",
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
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
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
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
            ),
        ]

        XCTAssertEqual(
            result, [
                .mutationTestOutcomeGenerated(
                    MutationTestOutcome(mutations: expectedTestOutcomes)
                ),
            ]
        )
    }

    func test_createLogFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            ioDelegate.testLogs,
            [
                "baseline run",
                "path_RelationalOperatorReplacement_0_0_0.log",
                "path_RelationalOperatorReplacement_0_0_0.log",
            ]
        )
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
            ["benchmarkTests(using:savingResultsIntoFileNamed:)",]
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
        let expect = expectation(
            forNotification: .baselineTestFailed,
            object: nil,
            notificationCenter: notificationCenter
        ) { notification in
            (notification.object as? MutationTestLog)?.mutationPoint == nil
        }

        // …and not as `.newTestLogAvailable`, which announces "Determined baseline for mutation
        // testing" and starts the progress bar — neither of which happened.
        let announcedSuccess = expectation(
            forNotification: .newTestLogAvailable,
            object: nil,
            notificationCenter: notificationCenter
        )
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
            "switchOn(schemata:for:at:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
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
            "switchOn(schemata:for:at:)",
            // First operator
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",

            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:)",

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
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project")
        )

        let expectedTestOutcomes = Array(repeating: expectedBuildErrorOutcome, count: 4) + [expectedFailingOutcome]

        XCTAssertEqual(result, [
            .mutationTestOutcomeGenerated(
                MutationTestOutcome(mutations: expectedTestOutcomes)
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
        let posted = recordNotifications(named: [.newMutationTestOutcomeAvailable])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(posted().count, 1)
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 2)
    }

    // A process killed before its run's cancellation handler is in place reads as one that exited by a signal:
    // a runtime error, which counts as killed. A run that returns once mutation testing is cancelled tested
    // nothing, whatever it says.
    func test_aRunThatReturnsAfterCancellation_isNotRecorded_whateverItsEnding() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .runtimeError, .failed]
        ioDelegate.mutantRunEndings = [.exited]
        ioDelegate.whileRunningMutant = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let posted = recordNotifications(named: [.newMutationTestOutcomeAvailable, .newTestLogAvailable])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // Only the baseline's log.
        XCTAssertEqual(posted().map(\.name), [.newTestLogAvailable])
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 1)
    }

    // Stopping the run kills the baseline run, which then fails. That says nothing about the project's tests, so the
    // run stops without saying they failed, and writes no results file.
    func test_aCancelledBaseline_throwsCancellation_andPostsNoBaselineFailure() async throws {
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.buildError]
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 0 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let posted = recordNotifications(named: [.baselineTestFailed])

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(posted().count, 0)
        XCTAssertEqual(resultsFiles.directories, [])
    }

    func test_whenCancelledBeforeTheFirstMutant_noneRuns() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        // The baseline's log is the last thing posted before the first mutant.
        cancelMutationTesting(whenPosted: .newTestLogAvailable)

        let result = await runInItsOwnTask()

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(ioDelegate.methodCalls, ["benchmarkTests(using:savingResultsIntoFileNamed:)"])
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
        let posted = recordNotifications(named: [.stopAtFirstFailureTurnedOff, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false])
        let notices = posted().filter { $0.name == .stopAtFirstFailureTurnedOff }
        XCTAssertEqual(notices.count, 1)
        let reason = try XCTUnwrap(notices.first?.object as? String)
        XCTAssertTrue(reason.hasSuffix("\n  \(lookalike)"), reason)
        // Before the baseline's log, which starts the progress bar.
        XCTAssertEqual(posted().first?.name, .stopAtFirstFailureTurnedOff)
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
        let posted = recordNotifications(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false])
        // Runs weren't going to stop at a failed test, so nothing changed that is worth a notice.
        XCTAssertEqual(posted().count, 0)
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
        let posted = recordNotifications(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [true, true])
        XCTAssertEqual(posted().count, 0)
    }

    func test_whenStopAtFirstFailureIsSetForXcodebuild_thenANoticeSaysItIsOff() async throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], stopAtFirstFailure: true
        )
        state.muterConfiguration = configuration
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let posted = recordNotifications(
            named: [.mutationTestingStarted, .stopAtFirstFailureTurnedOff, .newTestLogAvailable]
        )

        _ = try await sut.run(with: state)

        let names = posted().map(\.name)
        XCTAssertEqual(names.filter { $0 == .stopAtFirstFailureTurnedOff }.count, 1)
        // With the start of mutation testing, before the baseline's log starts the progress bar.
        XCTAssertEqual(
            Array(names.prefix(3)),
            [.mutationTestingStarted, .stopAtFirstFailureTurnedOff, .newTestLogAvailable]
        )
        let reason = try XCTUnwrap(configuration.stopAtFirstFailureUnsupportedReason)
        let notice = posted().first { $0.name == .stopAtFirstFailureTurnedOff }
        XCTAssertEqual(notice?.object as? String, reason)
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
    }

    func test_whenStopAtFirstFailureIsSetWithRepeatUntil_thenANoticeSaysItIsOff() async throws {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test", "--repeat-until", "pass"],
            stopAtFirstFailure: true
        )
        state.muterConfiguration = configuration
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let posted = recordNotifications(named: [.stopAtFirstFailureTurnedOff])

        _ = try await sut.run(with: state)

        XCTAssertEqual(posted().count, 1)
        let reason = try XCTUnwrap(posted().first?.object as? String)
        XCTAssertEqual(reason, configuration.stopAtFirstFailureUnsupportedReason)
        XCTAssertTrue(reason.contains("--repeat-until"), reason)
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false])
    }

    func test_whenStopAtFirstFailureIsUnset_thenNoNoticeIsPosted() async throws {
        let posted = recordNotifications(named: [.stopAtFirstFailureTurnedOff])

        // Only an explicit `true` asks for it, so a test command that can't use it is worth a notice only then.
        for stopAtFirstFailure in [nil, false] as [Bool?] {
            state.muterConfiguration = MuterConfiguration(
                executable: "/usr/bin/xcodebuild", arguments: ["test"], stopAtFirstFailure: stopAtFirstFailure
            )
            ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(posted().count, 0)
    }

    /// Records every notification posted with one of `names`, in order, until the test ends.
    private func recordNotifications(named names: [Notification.Name]) -> () -> [Notification] {
        var posted: [Notification] = []
        let tokens = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { posted.append($0) }
        }
        addTeardownBlock { [notificationCenter] in tokens.forEach(notificationCenter.removeObserver) }
        return { posted }
    }

    /// Runs mutation testing in a task of its own, so a test that cancels it mid-run doesn't cancel itself.
    private func runInItsOwnTask() async -> Result<[MutationTestState.Change], Error> {
        await Task { [sut, state] in try await sut.run(with: state) }.result
    }

    /// Cancels mutation testing when it posts `name`, from the task that posts it.
    private func cancelMutationTesting(whenPosted name: Notification.Name) {
        let observer = notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        addTeardownBlock { [notificationCenter] in notificationCenter.removeObserver(observer) }
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
