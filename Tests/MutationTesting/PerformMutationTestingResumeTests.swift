@testable import muterCore
import TestingExtensions
import XCTest

/// What a resumed run's mutation testing writes to the stopped run's results file, and the outcome it reports: it tests
/// only the mutants without a recorded result that still holds, and reports those it keeps with them, in job order.
final class PerformMutationTestingResumeTests: MuterTestCase {
    private let state = MutationTestState()
    private let resultsPath = "/project_muter_logs/session 1/results.jsonl"
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var clonedCounts: [Int] = []
    private let tree = ProjectTree(
        listedBy: .git,
        files: [
            "Sources/Product.swift": "77e0",
            "Sources/Quotient.swift": "3c4f",
            "Sources/Sum.swift": "5a1c",
            "Sources/Total.swift": "9e21",
        ],
        excluded: [],
        treeSHA256: "e5b8"
    )
    /// What the stopped run's only session recorded: a survivor and a kill that still hold, a build error, which is
    /// tested again, and a kill of a mutant this run no longer discovers. It never got to Total.swift's mutant.
    private lazy var recorded: [any Encodable] = [
        ResultsHeader.make(mutantsDiscovered: 5, mutantsToTest: 5, project: tree),
        record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
        record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d"),
        record(of: "Sources/Quotient.swift", line: 4, .buildError, fileSHA256: "3c4f"),
        record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
        ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 4),
    ]
    /// The provenance probed before the copy, which differs from the one `current.provenance` gives.
    private let checkedProvenance = Provenance(
        swiftMutator: .init(version: "1.0.0", executablePath: "/usr/local/bin/swift-mutator", executableSHA256: "4d1e"),
        toolchain: .init(testCommandVersion: "Apple Swift version 6.5", testExecutableSHA256: nil, environment: [:]),
        processIdentifier: 90210,
        host: "studio.local",
        arguments: ["--resume", "results.jsonl", "--force-resume"]
    )

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [unowned self] _, count in
            clonedCounts.append(count)
            return Array(repeating: workerClone, count: count)
        },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/project_muter_logs/session 2"
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.projectTree = tree
        // In discovery's order: files by path.
        state.mutationMapping = try [
            makeSchemataMapping(file: "Sources/Product.swift", line: 7),
            makeSchemataMapping(file: "Sources/Quotient.swift", line: 4),
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
            makeSchemataMapping(file: "Sources/Total.swift", line: 8),
        ]
        state.resumeWaived = ["README.md"]
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: resultsFiles.openForResume(at: resultsPath),
            provenance: checkedProvenance,
            forced: ["toolchain.testCommandVersion"],
            notices: ["mutationTestWorkers was 4 and is 1 now, which no result depends on."]
        )
    }

    // Product.swift's survivor and Sum.swift's kill still hold. Quotient.swift's build error and Total.swift's mutant,
    // which was never tested, are what is left.
    func test_recordedMutantsAreNotTestedAgain() async throws {
        // One for the baseline and each mutant, so that testing every mutant fails here rather than in the spy.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [
            "baseline run",
            "Quotient.swift_RelationalOperatorReplacement_40_4_5.log",
            "Total.swift_RelationalOperatorReplacement_80_8_5.log",
        ])
    }

    func test_aResumedSession_isTheNextNumber_withAFormat2Header_inTheSameFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var announced: [String] = []
        whenPosted(.resultsFileCreated) { announced.append(($0.object as? String) ?? "") }

        _ = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, [], "no new file is made")
        XCTAssertEqual(resultsFiles.files.map(\.path), [resultsPath])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "retired", "mutant", "mutant", "end"])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.session, 2)
        XCTAssertEqual(header.formatVersion, ResultsCoding.resumedFormatVersion)
        XCTAssertEqual(header.logDirectory, "/project_muter_logs/session 2", "the session's own log folder")
        XCTAssertEqual(header.mutantsDiscovered, 4)
        XCTAssertEqual(header.mutantsToTest, 2)
        XCTAssertEqual(header.mutantsReused, 2)
        XCTAssertEqual(header.project, tree)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.session), [2, 2])
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.session), [2])
        XCTAssertEqual(announced, [resultsPath])
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true], "the end line releases the lock")
    }

    func test_theNextNumber_followsTheFilesLastSession() async throws {
        recorded += [
            ResultsHeader.make(formatVersion: ResultsCoding.resumedFormatVersion, session: 2, project: tree),
            ResultsEnd.make(session: 2, reason: .interrupted),
        ]
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: resultsFiles.openForResume(at: resultsPath)
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.session), [3])
    }

    // Without its retired line, the file still stands by the earlier results this session tests again, and holds none
    // of its own, so the run mustn't name it as the place every result is in.
    func test_aRetiredLineThatCannotBeWritten_leavesTheFileUnannounced() async throws {
        resultsFiles.failFromLine = 2
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: resultsFiles.openForResume(at: resultsPath)
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var posted: [Notification.Name] = []
        whenPosted(.resultsFileCreated) { posted.append($0.name) }
        whenPosted(.resultsFileUnavailable) { posted.append($0.name) }

        _ = try await sut.run(with: state)

        XCTAssertEqual(posted, [.resultsFileUnavailable])
        XCTAssertEqual(try resultsFiles.kinds(), ["header"])
    }

    // A header is written once the baseline passes; before it, no line would belong to a session, so the resumed file
    // is left as the stopped run left it, and its lock goes.
    func test_aFailedBaseline_writesNothingToTheResumedFile() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(resultsFiles.lines, [])
        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
    }

    // The kept results still stand. Quotient.swift's build error is tested again, and Gone.swift's mutant is no longer
    // discovered, so neither earlier result does.
    func test_theRetiredLine_listsOnlyKeysNotKept() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let retired = try resultsFiles.records(ResultsRetired.self)
        XCTAssertEqual(retired.map(\.session), [2])
        XCTAssertEqual(
            retired.first?.keys,
            [
                MutantKey(path: "Sources/Gone.swift", mutationOperatorId: .ror, line: 2, column: 5, occurrence: 0),
                MutantKey(path: "Sources/Quotient.swift", mutationOperatorId: .ror, line: 4, column: 5, occurrence: 0),
            ]
        )
    }

    // The file already holds them, and the end line counts only this session's lines.
    func test_aReusedResult_isNotWrittenAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            try resultsFiles.records(MutantResult.self).map(\.path),
            ["Sources/Quotient.swift", "Sources/Total.swift"]
        )
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [2])
    }

    // A kept result's outcome is built from its job, as a tested one's is, and takes its place in job order.
    func test_mergesRecordedAndNewOutcomesInJobOrder() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [7, 4, 3, 8])
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
        XCTAssertEqual(
            outcome.mutations.first,
            MutationTestOutcome.Mutation(
                testSuiteOutcome: .passed,
                mutationPoint: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/project_mutated/Sources/Product.swift",
                    position: MutationPosition(utf8Offset: 70, line: 7, column: 5)
                ),
                mutationSnapshot: .make(before: ">", after: "<", description: "changed > to <"),
                originalProjectDirectoryUrl: state.projectDirectoryURL,
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL
            )
        )
    }

    // The mutants left are tested under this session's own baseline, whose time sets their default time limit.
    func test_theBaselineRunsAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.first, "benchmarkTests(using:savingResultsIntoFileNamed:)")
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumDefaultTimeout, PerformMutationTesting.minimumDefaultTimeout]
        )
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertNotNil(header.baselineSeconds)
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumDefaultTimeout)
    }

    // Every result still holds, so a baseline and clones would cost minutes and test nothing. The session is a header
    // and an end line, and the report covers every mutant.
    func test_nothingLeft_skipsTheBaselineNoticeBaselineAndClones_andEndsFinished() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4
        )
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = []
        let posted = recordNotifications(named: [.mutationTestingStarted, .newTestLogAvailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(posted().map(\.name), [], "no baseline notice, and no progress bar")
        XCTAssertEqual(ioDelegate.methodCalls, [], "no baseline, and no mutant")
        XCTAssertEqual(clonedCounts, [])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "end"])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.workers, 0)
        XCTAssertNil(header.baselineSeconds)
        XCTAssertEqual(header.mutantsToTest, 0)
        XCTAssertEqual(header.mutantsReused, 4)
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .finished)
        XCTAssertEqual(end.recorded, 0)
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .runtimeError, .failed, .timeout])
    }

    // The first session tested a kill between each two of the build errors it recorded, and those kills are kept, so
    // the build errors are tested again one after another. Failing to build again says nothing new about the build,
    // so they don't count toward stopping after 5 build errors in a row, or no resume of the run could finish.
    func test_buildErrorsTestedAgain_dontCountTowardTheAbort() async throws {
        let lines = Array(1...10)
        state.mutationMapping = try [makeSchemataMapping(file: "Sources/Sum.swift", lines: lines)]
        var recorded: [any Encodable] = [ResultsHeader.make(mutantsDiscovered: 10, mutantsToTest: 10, project: tree)]
        for line in lines {
            let outcome: TestSuiteOutcome = line.isMultiple(of: 2) ? .failed : .buildError
            recorded.append(record(of: "Sources/Sum.swift", line: line, outcome, fileSHA256: "5a1c"))
        }
        recorded.append(ResultsEnd.make(reason: .finished, recorded: 10))
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .buildError, count: 5)

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.line), [1, 3, 5, 7, 9])
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.reason), [.finished])
    }

    // Mutants never tested before still stop mutation testing after 5 build errors in a row, as in a first session.
    func test_newBuildErrors_stillStopItAfterFiveInARow() async throws {
        state.mutationMapping = try [makeSchemataMapping(file: "Sources/Sum.swift", lines: Array(1...10))]
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 10, mutantsToTest: 10, project: tree),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", recorded: 0),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .buildError, count: 5)

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )
    }

    // Two mutants are left, so a third and fourth worker would only cost clones.
    func test_workersAreCappedByWhatIsLeft() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4
        )
        // The baseline, the worker clone's build, then the two mutants left.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertEqual(
            Set(ioDelegate.testLogs.dropFirst(2)),
            [
                "Quotient.swift_RelationalOperatorReplacement_40_4_5.log",
                "Total.swift_RelationalOperatorReplacement_80_8_5.log",
            ]
        )
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [7, 4, 3, 8])
    }

    // What is reused and why the rest is tested is said first, and the progress bar counts only what is left.
    func test_theProgressTotalIsWhatIsLeft() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let posted = recordNotifications(named: [.resumePlanned, .mutationTestingStarted, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            posted().prefix(3).map(\.name),
            [.resumePlanned, .mutationTestingStarted, .newTestLogAvailable]
        )
        XCTAssertEqual(
            posted().first?.object as? ResumeSummary,
            ResumeSummary(
                path: resultsPath,
                reused: 2,
                toTest: 2,
                retestedBecause: [.buildError: 1, .notRecorded: 1],
                forced: ["toolchain.testCommandVersion"],
                waived: ["README.md"],
                notices: ["mutationTestWorkers was 4 and is 1 now, which no result depends on."]
            )
        )
        let baselineLog = try XCTUnwrap(posted().dropFirst(2).first?.object as? MutationTestLog)
        XCTAssertNil(baselineLog.mutationPoint)
        XCTAssertEqual(baselineLog.remainingMutationPointsCount, 2)
    }

    // The reporter gets every outcome the report covers, so the Xcode format warns of the kept survivor too. Only the
    // tested mutants post a log, which moves the progress bar and is kept in the session's log folder.
    func test_reusedOutcomesReachTheXcodeReporter_butNoTestLogIsPosted() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let outcomes = recordNotifications(named: [.newMutationTestOutcomeAvailable])
        let testLogs = recordNotifications(named: [.newTestLogAvailable])

        _ = try await sut.run(with: state)

        let posted = outcomes().compactMap { $0.object as? MutationTestOutcome.Mutation }
        XCTAssertEqual(posted.map(\.point.position.line), [7, 3, 4, 8], "the kept ones first, then each as it is tested")
        XCTAssertEqual(posted.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
        XCTAssertEqual(
            testLogs().map { ($0.object as? MutationTestLog)?.mutationPoint?.position.line },
            [nil, 4, 8],
            "the baseline's, then the tested mutants'"
        )
    }

    // A stop while Total.swift's mutant runs: the partial report has both kept results and Quotient.swift's, and says
    // how many were kept.
    func test_anInterruptedResumedSession_postsReusedAndNewOutcomes_withItsReusedCount() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var earlyEnds: [EarlyEnd] = []
        whenPosted(.mutationTestingEndedEarly) { notification in
            if let earlyEnd = notification.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnds.count, 1)
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.point.position.line), [7, 4, 3])
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed])
        XCTAssertEqual(earlyEnd.reused, 2)
        XCTAssertEqual(earlyEnd.discovered, 4)
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [1])
    }

    // The report covers the whole run, so its duration does too; the end line keeps each session's apart.
    func test_theOutcomesDuration_addsEarlierSessions_whileTheEndLineHasThisOnesOnly() async throws {
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
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertGreaterThan(end.testDurationSeconds, 0)
        XCTAssertEqual(outcome.testDuration, 100.5 + end.testDurationSeconds)
    }

    func test_anEarlyEndsDuration_addsEarlierSessions_too() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var earlyEnds: [EarlyEnd] = []
        whenPosted(.mutationTestingEndedEarly) { notification in
            if let earlyEnd = notification.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await Task { [sut, state] in try await sut.run(with: state) }.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(earlyEnds.map(\.outcome.testDuration), [100.5 + end.testDurationSeconds])
    }

    // What was checked before the copy is what is recorded, and the provenance isn't probed again.
    func test_forcedWaivedAndProvenance_comeFromTheResumeState() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var probed = 0
        current.provenance = { _ in
            probed += 1
            return .fixture
        }

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.provenance, checkedProvenance)
        XCTAssertEqual(header.forced, ["toolchain.testCommandVersion"])
        XCTAssertEqual(header.waived, ["README.md"])
        XCTAssertEqual(probed, 0)
    }

    // `swift-mutator report` reads the whole file: the stopped run's lines, then this session's. The kept results come
    // from the earlier session's lines, and the rest from this one's.
    func test_aResumedReport_equalsTheReportFromTheFile() async throws {
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
        let file = try resultsFileData(recorded) + Data(resultsFiles.lines.map { $0 + "\n" }.joined().utf8)
        let fromTheFile = try RecordedResults.read(file, path: resultsPath).mutationTestOutcome()
        XCTAssertEqual(fromTheFile, outcome)
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
    }
}

private extension PerformMutationTestingResumeTests {
    /// The notifications posted with any of `names` so far, in order.
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

    /// The stopped run's record of the mutant `makeSchemataMapping(file:line:)` makes, as it wrote it.
    func record(of file: String, line: Int, _ outcome: TestSuiteOutcome, fileSHA256: String) -> MutantResult {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let operatorId = MutationOperator.Id.ror
        return MutantResult.make(
            path: file,
            line: line,
            column: 5,
            utf8Offset: line * 10,
            mutationOperatorId: operatorId,
            switchID: "\(name)_\(operatorId.rawValue)_\(line)_5_\(line * 10)",
            outcome: outcome,
            fileSHA256: fileSHA256
        )
    }

    /// A file in the mutated project with one mutant, at `line`, column 5.
    func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try makeSchemataMapping(file: file, lines: [line])
    }

    /// A file in the mutated project with a mutant at each of `lines`, column 5.
    func makeSchemataMapping(file: String, lines: [Int]) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/\(file)",
            (
                source: "func bar() { }",
                schemata: lines.map { line in
                    try .make(
                        filePath: "/project_mutated/\(file)",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    )
                }
            )
        )
    }
}
