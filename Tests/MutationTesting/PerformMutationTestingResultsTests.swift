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

    func test_aKilledMutantNamesItsFailedTests() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog, "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."]

        _ = try await sut.run(with: state)

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

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.failedTestLinesAreReliable), [false])
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.outcome), [.failed, .failed])
        XCTAssertEqual(mutants.map(\.killedBy), [nil, nil])
        XCTAssertEqual(mutants.map(\.failedTestCount), [nil, nil])
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

    func test_whenTheResultsFileCannotBeCreated_theRunGoesOn_andSaysSo() async throws {
        resultsFiles.errorToThrow = ResultsFileError.cannotOpen(path: "/logs/results.jsonl", errno: EACCES)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let posted = recordNotifications(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(posted().map(\.name), [.resultsFileUnavailable])
        XCTAssertEqual(posted().first?.object as? String, "can't open /logs/results.jsonl: Permission denied")
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
    }

    func test_whenAWriteFails_itIsSaidOnce_andTheRunGoesOn() async throws {
        // The header is written; every line after it fails.
        resultsFiles.failFromLine = 2
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
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
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
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
        let posted = recordNotifications(named: [.resultsFileCreated, .resultsFileUnavailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(posted().count, 0)
    }
}

private extension PerformMutationTestingResultsTests {
    /// Records every notification posted with one of `names`, in order, until the test ends.
    func recordNotifications(named names: [Notification.Name]) -> () -> [Notification] {
        var posted: [Notification] = []
        for name in names {
            whenPosted(name) { posted.append($0) }
        }
        return { posted }
    }

    /// Calls `handler` with each notification posted with `name`, from the task that posts it, until the test ends.
    func whenPosted(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        let observer = notificationCenter.addObserver(forName: name, object: nil, queue: nil, using: handler)
        addTeardownBlock { [notificationCenter] in notificationCenter.removeObserver(observer) }
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
