@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// What mutation testing writes to the run's results file as it goes.
final class PerformMutationTestingResultsTests: MuterTestCase {
    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private let killingLog = """
    ◇ Test run started.
    ✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4
    ✘ Test sum() failed after 0.001 seconds with 1 issue.
    ✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue.
    """

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutationMapping = try [
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
            makeSchemataMapping(file: "Sources/Product.swift", line: 7),
        ]
    }

    func test_theHeaderIsWrittenOnceTheBaselinePasses_withEffectiveTimeoutWorkersAndCounts() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var probed: [MuterConfiguration] = []
        current.provenance = { configuration in
            probed.append(configuration)
            return .fixture
        }
        var linesAtTheBaselinesLog: [String]?
        whenPosted(.newTestLogAvailable) { notification in
            if (notification.object as? MutationTestLog)?.mutationPoint == nil {
                linesAtTheBaselinesLog = self.resultsFiles.lines
            }
        }
        let posted = recordNotifications(named: [.resultsFileCreated, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, ["/logs"])
        let headers = try resultsFiles.records(ResultsHeader.self)
        XCTAssertEqual(headers.count, 1)
        let header = try XCTUnwrap(headers.first)
        XCTAssertEqual(try resultsFiles.kinds().first, "header")
        XCTAssertEqual(header.session, 1)
        XCTAssertEqual(header.startedAt, current.now())
        XCTAssertEqual(header.provenance, .fixture)
        XCTAssertEqual(probed, [state.muterConfiguration], "the configuration as loaded is probed, once")
        XCTAssertEqual(header.configuration, state.muterConfiguration)
        XCTAssertEqual(header.logDirectory, "/logs")
        XCTAssertEqual(header.mutatedProjectPath, "/project_mutated")
        // The spy's baseline returns at once, so the minimum default applies.
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumDefaultTimeout)
        XCTAssertTrue(header.timeoutIsDefault)
        XCTAssertEqual(header.workers, 1)
        XCTAssertTrue(header.failedTestLinesAreReliable)
        XCTAssertEqual(header.mutantsDiscovered, 2)
        XCTAssertEqual(header.mutantsToTest, 2)
        // Before the baseline's log, which starts the progress bar, so the file's path is printed first.
        XCTAssertEqual(linesAtTheBaselinesLog?.count, 1)
        XCTAssertEqual(posted().prefix(2).map(\.name), [.resultsFileCreated, .newTestLogAvailable])
        XCTAssertEqual(posted().first?.object as? String, "/logs/results.jsonl")
    }

    func test_theHeaderRecordsTheProjectTree() async throws {
        let tree = makeProjectTree(["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "77e0", "README.md": "0b9d"])
        state.projectTree = tree
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.project), [tree])
    }

    // A test plan's run copies nothing, so its state has no tree, and neither does its header.
    func test_aStateWithoutAProjectTree_writesAHeaderWithoutOne_andMutantLinesWithoutHashes() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.project), [nil])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.fileSHA256), [nil, nil])
    }

    // No more workers run than there are mutants, and the header says how many ran.
    func test_theHeadersWorkers_areTheEffectiveCount_whenMoreAreConfiguredThanThereAreMutants() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4
        )
        // The baseline, the one worker clone's build, then the two mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 2)
        XCTAssertEqual(header.configuration.mutationTestWorkers, 4, "the configuration is kept as loaded")
        XCTAssertEqual(ioDelegate.builtWorkerDirectories, [workerClone])
    }

    func test_noResultsFileWhenTheBaselineFails() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(resultsFiles.directories, [])
    }

    func test_eachMutantsLineIsWrittenBeforeItsNotifications() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var mutantLinesAtEachOutcome: [Int] = []
        var mutantLinesAtEachLog: [Int] = []
        whenPosted(.newMutationTestOutcomeAvailable) { _ in
            mutantLinesAtEachOutcome.append((try? self.resultsFiles.records(MutantResult.self).count) ?? -1)
        }
        whenPosted(.newTestLogAvailable) { notification in
            guard (notification.object as? MutationTestLog)?.mutationPoint != nil else { return }
            mutantLinesAtEachLog.append((try? self.resultsFiles.records(MutantResult.self).count) ?? -1)
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(mutantLinesAtEachOutcome, [1, 2])
        XCTAssertEqual(mutantLinesAtEachLog, [1, 2])
    }

    func test_aMutantLineCarriesKeyPathOutcomeEndingDurationAndWorker() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .passed]
        ioDelegate.mutantRunEndings = [.timedOut, .exited]
        var ticks: UInt64 = 0
        current.instant = {
            ticks += 1
            return DispatchTime(uptimeNanoseconds: ticks * 1_500_000_000)
        }
        let schemata = state.mutationMapping.flatMap(\.mutationSchemata)

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.key), [
            MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 5, occurrence: 0),
            MutantKey(path: "Sources/Product.swift", mutationOperatorId: .ror, line: 7, column: 5, occurrence: 0),
        ])
        XCTAssertEqual(mutants.map(\.session), [1, 1])
        XCTAssertEqual(mutants.map(\.outcome), [.timeout, .passed])
        XCTAssertEqual(mutants.map(\.endedBy), [.timedOut, .exited])
        XCTAssertEqual(mutants.map(\.durationSeconds), [1.5, 1.5])
        XCTAssertEqual(mutants.map(\.worker), [0, 0])
        XCTAssertEqual(mutants.map(\.finishedAt), [current.now(), current.now()])
        XCTAssertEqual(mutants.map(\.switchID), schemata.map(\.id))
        XCTAssertEqual(mutants.map(\.utf8Offset), [30, 70])
        XCTAssertEqual(mutants.map(\.snapshot), schemata.map(\.snapshot))
        XCTAssertEqual(mutants.map(\.log), [
            "RelationalOperatorReplacement @ Sum.swift-3-5.log",
            "RelationalOperatorReplacement @ Product.swift-7-5.log",
        ])
    }

    // The hash of the file as the copy held it before discovery rewrote it, so a later run can tell whether the
    // mutant's file is still the one it was tested in.
    func test_aMutantLineCarriesItsFilesHash() async throws {
        let tree = makeProjectTree(["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "77e0", "README.md": "0b9d"])
        state.projectTree = tree
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.path), ["Sources/Sum.swift", "Sources/Product.swift"])
        XCTAssertEqual(mutants.first?.fileSHA256, tree.files["Sources/Sum.swift"])
        XCTAssertEqual(mutants.map(\.fileSHA256), ["5a1c", "77e0"])
    }

    func test_parallelLines_nameTheirWorker_andMatchTheJobsByKey() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...4).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        // The baseline, the worker clone's build, then the four mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 4)
        // The first run to start waits until the last one has started, so the other worker runs the other three
        // mutants meanwhile and the runs finish out of job order. A line given the key of the job that finished in
        // its place would then disagree with itself. The wait is bounded, so the test can't hang.
        let lastRunStarted = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = lastRunStarted.wait(timeout: .now() + 5) }
            if number == 3 { lastRunStarted.signal() }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(
            Set(mutants.map(\.key)),
            Set((1...4).map {
                MutantKey(path: "Sources/File\($0).swift", mutationOperatorId: .ror, line: $0, column: 5, occurrence: 0)
            })
        )
        // The lines' order is the order the runs finished in, told by what each takes from its schema, not its key.
        XCTAssertNotEqual(mutants.map(\.utf8Offset), [10, 20, 30, 40], "the runs didn't finish out of job order")
        // Each line's key is its own mutant's: everything the line takes from the mutant's schema agrees with it.
        let schemata = state.mutationMapping.flatMap(\.mutationSchemata)
        for mutant in mutants {
            let schema = try XCTUnwrap(schemata.first { $0.filePath == "/project_mutated/\(mutant.path)" })
            XCTAssertEqual(mutant.utf8Offset, schema.position.utf8Offset, "\(mutant.key)")
            XCTAssertEqual(mutant.switchID, schema.id, "\(mutant.key)")
            XCTAssertEqual(
                mutant.log,
                "RelationalOperatorReplacement @ File\(mutant.line).swift-\(mutant.line)-5.log",
                "\(mutant.key)"
            )
        }
        XCTAssertEqual(Set(mutants.map(\.worker)), [0, 1])
        // Each line names the worker whose folder its mutant ran in.
        let ranIn = { (directory: URL) in self.ioDelegate.workingDirectories.filter { $0 == directory }.count }
        XCTAssertEqual(mutants.filter { $0.worker == 0 }.count, ranIn(state.mutatedProjectDirectoryURL))
        XCTAssertEqual(mutants.filter { $0.worker == 1 }.count, ranIn(workerClone))
    }

    // The outcome the run reports names them as its results line does.
    func test_aKilledMutantNamesItsFailedTests() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog, "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."]

        let changes = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.count, 2)
        XCTAssertEqual(mutants.first?.killedBy, [.init(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertEqual(mutants.first?.failedTestCount, 1)
        XCTAssertEqual(
            mutants.first?.firstFailedTestLine,
            "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
        )
        XCTAssertNil(mutants.last?.killedBy)
        XCTAssertNil(mutants.last?.failedTestCount)
        let reported = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(reported.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        let line = try XCTUnwrap(mutants.first)
        XCTAssertEqual(reported.mutations.first?.killingTests, MutationTestOutcome.KillingTests(line))
        XCTAssertEqual(reported.mutations.first?.killingTests, sumKilled)
        XCTAssertNil(reported.mutations.last?.killingTests)
    }

    // Such lines then name no test the mutant failed.
    func test_noKilledByWhenTheBaselinePrintedAFailureLikeLine() async throws {
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        ✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 1 == 2
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantTestLogs = [killingLog, killingLog]

        let changes = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.failedTestLinesAreReliable), [false])
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.outcome), [.failed, .failed])
        XCTAssertEqual(mutants.map(\.killedBy), [nil, nil])
        XCTAssertEqual(mutants.map(\.failedTestCount), [nil, nil])
        XCTAssertEqual(try XCTUnwrap(outcome(of: changes)).mutations.map(\.killingTests), [nil, nil])
    }

    func test_repeatedMutants_getDistinctKeys() async throws {
        state.mutationMapping = try [
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
        ]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.path), ["Sources/Sum.swift", "Sources/Sum.swift"])
        XCTAssertEqual(mutants.map(\.occurrence), [0, 1])
        XCTAssertEqual(mutants.map(\.outcome), [.failed, .passed])
    }

    func test_aFinishedRun_endsWithAnEndLine_whoseDurationIsTheOutcomes() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var calls = 0.0
        current.now = {
            calls += 1
            return ResultsHeader.fixedStart.addingTimeInterval(calls * 2.5)
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
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
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.outcome), Array(repeating: .buildError, count: 5))
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

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

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
        whenPosted(.mutationTestingEndedEarly) { notification in
            if let earlyEnd = notification.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(end.detail, "SIGTERM")
        XCTAssertEqual(earlyEnds.map(\.reason), [.interrupted])
        XCTAssertEqual(earlyEnds.map(\.detail), ["SIGTERM"])
    }

    // Stopping the run kills the clones' builds, which then fail, but no clone was at fault.
    func test_aCancelledWorkerBuild_endsInterrupted() async throws {
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
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "end"])
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertNil(end.detail)
        XCTAssertEqual(end.recorded, 0)
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
        whenPosted(.newMutationTestOutcomeAvailable) { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await Task { [state] in try await removals.sut.run(with: state) }.result

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
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
            removeWorkerDirectories: { _ in events.append("clones removed") }
        )
        whenPosted(.mutationTestingEndedEarly) { [resultsFiles] _ in
            events.append("early end posted after the \((try? resultsFiles.kinds().last) ?? "no") line")
        }
        whenPosted(.newMutationTestOutcomeAvailable) { _ in withUnsafeCurrentTask { $0?.cancel() } }

        let result = await Task { [state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(events, ["early end posted after the end line", "clones removed"])
    }

    func test_whenTheResultsFileCannotBeCreated_theRunGoesOn_andSaysSo() async throws {
        resultsFiles.errorToThrow = ResultsFileError.cannotOpen(path: "/logs/results.jsonl", errno: EACCES)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog]
        let posted = recordNotifications(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(posted().map(\.name), [.resultsFileUnavailable])
        XCTAssertEqual(posted().first?.object as? String, "can't open /logs/results.jsonl: Permission denied")
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(outcome.mutations.first?.killingTests, sumKilled, "worked out without a results file")
    }

    // The second mutant's line isn't even built, and its outcome still names its tests.
    func test_whenAWriteFails_itIsSaidOnce_andTheRunGoesOn() async throws {
        // The header is written; every line after it fails.
        resultsFiles.failFromLine = 2
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantTestLogs = [killingLog, killingLog]
        let posted = recordNotifications(named: [.resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(posted().count, 1)
        XCTAssertEqual(
            posted().first?.object as? String,
            "can't write to /logs/results.jsonl: No space left on device"
        )
        XCTAssertEqual(try resultsFiles.kinds(), ["header"])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .failed])
        XCTAssertEqual(outcome.mutations.map(\.killingTests), [sumKilled, sumKilled], "worked out after a failed write")
    }

    // A file without its header isn't a results file, so it isn't announced as one.
    func test_whenTheHeaderCannotBeWritten_theFileIsNotAnnounced_andTheRunGoesOn() async throws {
        resultsFiles.failFromLine = 1
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let posted = recordNotifications(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(posted().map(\.name), [.resultsFileUnavailable])
        XCTAssertEqual(resultsFiles.lines, [])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.count, 2)
    }

    func test_aStateWithoutALogFolder_writesNoResults() async throws {
        state.loggingDirectory = ""
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog]
        let posted = recordNotifications(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(posted().count, 0)
        XCTAssertEqual(
            try XCTUnwrap(outcome(of: changes)).mutations.first?.killingTests,
            sumKilled,
            "worked out without a results file"
        )
    }
}

private extension PerformMutationTestingResultsTests {
    /// What `killingLog` names, for a run that exited by itself.
    var sumKilled: MutationTestOutcome.KillingTests {
        MutationTestOutcome.KillingTests(
            tests: [FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")],
            count: 1,
            isComplete: true
        )
    }

    /// The outcome mutation testing that made `changes` reports, if it made one.
    func outcome(of changes: [MutationTestState.Change]) -> MutationTestOutcome? {
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else { return nil }
        return outcome
    }

    /// Records every notification posted with one of `names`, in order, until the test ends.
    func recordNotifications(named names: [Notification.Name]) -> () -> [Notification] {
        var posted: [Notification] = []
        for name in names {
            whenPosted(name) { posted.append($0) }
        }
        return { posted }
    }

    /// Mutation testing whose worker clone is `workerClone`, and whose clone removal records the kinds of the results
    /// lines written by then, once for each removal.
    func removingClonesRecordsTheResultsLines() -> (sut: PerformMutationTesting, kindsAtEach: () -> [[String]]) {
        var kindsAtEach: [[String]] = []
        let sut = PerformMutationTesting(
            makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
            removeWorkerDirectories: { [workerClone, resultsFiles] clones in
                XCTAssertEqual(clones, [workerClone])
                kindsAtEach.append((try? resultsFiles.kinds()) ?? [])
            }
        )
        return (sut, { kindsAtEach })
    }

    /// Calls `handler` with each notification posted with `name`, from the task that posts it, until the test ends.
    func whenPosted(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        let observer = notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: handler)
        addTeardownBlock { [notificationCenter] in notificationCenter.removeObserver(observer) }
    }

    /// A tree of `files`, each a path relative to the project and its hash.
    func makeProjectTree(_ files: [String: String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    /// A file in the mutated project with one mutant, at `line`, column 5.
    func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/\(file)",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/\(file)",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    ),
                ]
            )
        )
    }
}
