@testable import muterCore
import TestingExtensions
import XCTest

/// What a resumed run's mutation testing writes to the stopped run's results file, and the outcome it reports: it tests
/// only the mutants without a recorded result that still holds, and reports those it keeps with them, in job order.
final class PerformMutationTestingResumeTests: MuterTestCase {
    private let state = MutationTestState()
    private let resultsPath = "/project_muter_logs/session 1/results.jsonl"
    /// The note this session leaves in its own log folder, naming the file.
    private let notePath = "/project_muter_logs/session 2/resumed session.txt"
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var clonedCounts: [Int] = []
    private static let files = [
        "Sources/Product.swift": "77e0",
        "Sources/Quotient.swift": "3c4f",
        "Sources/Sum.swift": "5a1c",
        "Sources/Total.swift": "9e21",
    ]
    /// With its real `treeSHA256`, which a resumed header's `projectDelta` is read back against.
    private let tree = ProjectTree(
        listedBy: .git,
        files: files,
        excluded: [],
        treeSHA256: ProjectTree.treeHash(of: files)
    )
    /// The test the stopped run recorded failing for Sum.swift's mutant.
    private let sumTest = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
    /// What the stopped run's only session recorded: a survivor and a kill that still hold, a build error, which is
    /// tested again, and a kill of a mutant this run no longer discovers. It never got to Total.swift's mutant.
    private lazy var recorded: [any Encodable] = [
        ResultsHeader.make(mutantsDiscovered: 5, mutantsToTest: 5, project: tree),
        record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
        record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d"),
        record(of: "Sources/Quotient.swift", line: 4, .buildError, fileSHA256: "3c4f"),
        record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
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

    // A resume tests the kills an earlier session didn't, out of what that session left of the limit, and leaves those
    // it did, so stopping a run doesn't test more than running it through.
    func test_aResume_testsAloneOnlyWhatTheEarlierSessionDidnt_withinTheLimitLeft() async throws {
        let alone = MutantResult.Rerun(
            because: MutantResult.Rerun.onlySuspectTestsFailed,
            workers: 1,
            alone: [.init(name: "sum()", file: "SumTests.swift", result: MutantResult.Rerun.TestAlone.failedAgain)]
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            suspectTestFilePercent: 1,
            suspectTestMinimumFiles: 1,
            suspectKillReruns: 2
        )
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(
                    mutantsDiscovered: 4, mutantsToTest: 4, project: tree, configuration: state.muterConfiguration
                ),
                record(of: "Sources/Product.swift", line: 7, .failed, fileSHA256: "77e0", killedBy: [sumTest]),
                record(
                    of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest], rerun: alone
                ),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 2),
            ],
            file: resultsFiles.openForResume(at: resultsPath),
            provenance: checkedProvenance,
            forced: [],
            notices: []
        )
        // The baseline, the 2 mutants never tested, and Product.swift's kill alone.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .failed]
        ioDelegate.mutantTestLogs = ["testLog", "testLog", "✘ Test sum() recorded an issue at SumTests.swift:3:5: No"]

        _ = try await sut.run(with: state)

        let reruns = ioDelegate.testLogs.filter { $0.contains("_rerun_") }
        XCTAssertEqual(reruns.count, 1, "\(ioDelegate.testLogs)")
        XCTAssertTrue(reruns.first?.contains("Product.swift") == true, "\(reruns)")
    }

    // Product.swift's survivor and Sum.swift's kill still hold. Quotient.swift's build error and Total.swift's mutant,
    // which was never tested, are what is left.
    func test_recordedMutantsAreNotTestedAgain() async throws {
        // One for the baseline and each mutant, so that testing every mutant fails here rather than in the spy.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [
            running("baseline run"),
            running("timed test run"),
            running("1_Quotient.swift_RelationalOperatorReplacement_40_4_5.log"),
            running("3_Total.swift_RelationalOperatorReplacement_80_8_5.log"),
        ])
    }

    // A resumed run of a test plan judges its results by the copy as it is tested: a file of the copy fixed by hand
    // since the last session, which --resume-ignoring let through, has its mutants tested again, and an unchanged one
    // keeps its results. The header records the plan again.
    func test_aResumedTestPlansSession_keepsTheResultsOfUnchangedCopyFiles_andRetestsAnEditedOnes() async throws {
        let plan = LoadedTestPlan(
            path: "/project/muter-mappings.json",
            sha256: "91a",
            formatVersion: TestPlanCoding.formatVersion,
            swiftMutatorVersion: "16",
            scope: nil,
            sources: nil,
            mutatedFiles: nil,
            linkedFiles: nil,
            mutatedPaths: []
        )
        state.runOptions = .make(
            testPlanURL: URL(fileURLWithPath: plan.path),
            resumeURL: URL(fileURLWithPath: resultsPath),
            resumeIgnoring: ["Sources/Sum.swift"]
        )
        state.testPlan = plan
        var edited = tree.files
        edited["Sources/Sum.swift"] = "5a1d"
        state.projectTree = ProjectTree(listedBy: .git, files: edited, excluded: [], treeSHA256: "e5b9")
        let sent = recordEvents(named: [.resumePlanned])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [
            running("baseline run"),
            running("timed test run"),
            running("1_Quotient.swift_RelationalOperatorReplacement_40_4_5.log"),
            running("2_Sum.swift_RelationalOperatorReplacement_30_3_5.log"),
            running("3_Total.swift_RelationalOperatorReplacement_80_8_5.log"),
        ])
        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.retestedBecause, [.buildError: 1, .fileChanged: 1, .notRecorded: 1])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertTrue(header.usingTestPlan)
        XCTAssertEqual(header.testPlan, TestPlanRecord(plan))
        XCTAssertEqual(header.projectDelta?.files["Sources/Sum.swift"], "5a1d")
        XCTAssertEqual(header.mutantsReused, 1)
    }

    // Its kills may keep no log, so its mutant lines may have no `log`, which only a format-4 reader reads.
    func test_aResumedSession_isTheNextNumber_withAFormat4Header_inTheSameFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var announced: [String] = []
        whenSent(.resultsFileCreated) { announced.append(($0.object as? String) ?? "") }

        _ = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, [], "no new file is made")
        XCTAssertEqual(resultsFiles.files.map(\.path), [resultsPath])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "retired", "mutant", "mutant", "end"])
        XCTAssertEqual(resultsFiles.files.first?.batches, [0 ..< 2], "the header and the retired line go together")
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.session, 2)
        XCTAssertEqual(header.formatVersion, ResultsCoding.omittedLogsFormatVersion)
        XCTAssertEqual(header.logDirectory, "/project_muter_logs/session 2", "the session's own log folder")
        XCTAssertEqual(header.mutantsDiscovered, 4)
        XCTAssertEqual(header.mutantsToTest, 2)
        XCTAssertEqual(header.mutantsReused, 2)
        // Nothing changed since the last session, so its tree is that one's, by its hash, with no file.
        XCTAssertNil(header.project)
        XCTAssertEqual(header.projectDelta, ProjectTreeDelta(from: tree, to: tree))
        XCTAssertEqual(header.projectDelta?.files, [:])
        let file = try resultsFileData(recorded) + Data(resultsFiles.lines.map { $0 + "\n" }.joined().utf8)
        XCTAssertEqual(try RecordedResults.read(file, path: resultsPath).headers.map(\.project), [tree, tree])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.session), [2, 2])
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.session), [2])
        XCTAssertEqual(announced, [resultsPath])
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true], "the end line releases the lock")
    }

    // Its own log folder holds no results file, so the note names the one it adds to, on a line of its own, before the
    // run announces the file.
    func test_aResumedSession_leavesANoteInItsLogFolder_namingTheResultsFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var notedWhenAnnounced: [Bool] = []
        whenSent(.resultsFileCreated) { [fileManager, notePath] _ in
            notedWhenAnnounced.append(fileManager.createdFiles[notePath] != nil)
        }

        _ = try await sut.run(with: state)

        let note = try XCTUnwrap(fileManager.createdFiles[notePath].map { String(decoding: $0, as: UTF8.self) })
        XCTAssertTrue(note.hasPrefix(resultsPath + "\n\n"), note)
        XCTAssertEqual(note, ResultsFile.note(pointingTo: resultsPath, session: 2))
        XCTAssertTrue(note.contains("session 2 of a resumed run"), note)
        XCTAssertEqual(notedWhenAnnounced, [true])
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

    // Every earlier result still holds, so there is nothing to retire, and the header is written alone.
    func test_aResumedSessionThatRetiresNothing_writesItsHeaderAlone() async throws {
        recorded = [
            ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
            record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
            record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
            ResultsEnd.make(reason: .interrupted, recorded: 2),
        ]
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: resultsFiles.openForResume(at: resultsPath)
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "end"])
        XCTAssertEqual(resultsFiles.files.last?.batches, [0 ..< 1], "the file this session opened")
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
        var sent: [RunEvent.Name] = []
        whenSent(.resultsFileCreated) { sent.append($0.name) }
        whenSent(.resultsFileUnavailable) { sent.append($0.name) }

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent, [.resultsFileUnavailable])
        XCTAssertEqual(try resultsFiles.kinds(), ["header"])
        XCTAssertNil(fileManager.createdFiles[notePath], "the folder names a file that stands by results it doesn't")
    }

    // A header is written once the baseline passes; before it, no line would belong to a session, so the resumed file
    // is left as the stopped run left it, and its lock goes.
    func test_aFailedBaseline_writesNothingToTheResumedFile() async throws {
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(resultsFiles.lines, [])
        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
        XCTAssertNil(fileManager.createdFiles[notePath], "the session added nothing to the file")
    }

    // So is a stop during the timed test run after the baseline: the session hasn't started its results, so it sends
    // no early end, which could only say that none of the mutants has a result, although two have.
    func test_aStopDuringTheTimedTestRun_writesNothingToTheResumedFile_andPostsNoEarlyEnd() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.timedTestRunOutcome = .buildError
        ioDelegate.whileRunningTestsWithoutBuilding = { withUnsafeCurrentTask { $0?.cancel() } }
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(sent().count, 0)
        XCTAssertEqual(resultsFiles.lines, [])
        XCTAssertEqual(resultsFiles.files.map(\.isClosed), [true])
        XCTAssertNil(fileManager.createdFiles[notePath])
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
                mutatedProjectDirectoryURL: state.mutatedProjectDirectoryURL,
                killingTests: nil,
                reusedFrom: nil,
                // As its results line records them.
                key: MutantKey(
                    path: "Sources/Product.swift", mutationOperatorId: .ror, line: 7, column: 5, occurrence: 0
                ),
                durationSeconds: 31.25
            )
        )
    }

    // A kept kill isn't tested again, so the tests its line names are the only ones it has.
    func test_aKeptKill_keepsItsKillingTests() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [7, 4, 3, 8])
        XCTAssertEqual(
            outcome.mutations[2].killingTests,
            MutationTestOutcome.KillingTests(tests: [sumTest], count: 1, isComplete: true)
        )
        XCTAssertNil(outcome.mutations[0].killingTests, "a kept survivor names none")
    }

    // The mutants left are tested under this session's own baseline, and its own timed test run, which sets their
    // default time limit.
    func test_theBaselineRunsAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.prefix(2), [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "runTestsWithoutBuilding(using:savingResultsIntoFileNamed:)",
        ])
        // The spy's timed test run returns at once, so the minimum applies.
        XCTAssertEqual(
            ioDelegate.configurations.map(\.testSuiteTimeout),
            [PerformMutationTesting.minimumTestRunTimeout, PerformMutationTesting.minimumTestRunTimeout]
        )
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertNotNil(header.baselineSeconds)
        XCTAssertNotNil(header.testRunSeconds)
        XCTAssertEqual(header.timeoutSeconds, PerformMutationTesting.minimumTestRunTimeout)
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
        let sent = recordEvents(named: [.mutationTestingStarted, .newTestLogAvailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(sent().map(\.name), [], "no baseline notice, and no progress bar")
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
        XCTAssertEqual(
            fileManager.createdFiles[notePath],
            Data(ResultsFile.note(pointingTo: resultsPath, session: 2).utf8),
            "the session added to the file, though it kept no log"
        )
    }

    // Every mutant line it writes names a log, so it keeps to the format a resumed session had before format 4.
    func test_aResumedSessionKeepingAllLogs_hasAFormat3Header() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: true
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.formatVersion, ResultsCoding.projectDeltaFormatVersion)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map { $0.log != nil }, [true, true])
    }

    // It writes no mutant line, so nothing in it needs format 4.
    func test_aResumedSessionWithNothingLeft_hasAFormat3Header() async throws {
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = []

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.mutantsToTest, 0)
        XCTAssertEqual(header.formatVersion, ResultsCoding.projectDeltaFormatVersion)
    }

    // The note is all a session with nothing left to test keeps in its log folder, and it keeps the folder, which
    // the run removes at the end only when it is empty.
    func test_nothingLeft_keepsItsLogFolder_holdingTheNote() async throws {
        current.fileManager = FileManager.default
        let folder = try makeTemporaryDirectory()
        state.loggingDirectory = folder
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(reason: .finished, testDurationSeconds: 100.5, recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file
        )

        _ = try await sut.run(with: state)
        removeFolderIfEmpty(atPath: folder, fileManager: FileManager.default)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [ResultsFile.noteFileName])
        XCTAssertEqual(try ResultsFile.find(at: folder, using: FileManager.default), resultsPath)
    }

    // The first session, on 4 workers, was stopped while it ran its timeouts again: Sum.swift's was run again, and
    // killed, Total.swift's wasn't. Only that one is tested, and the rerun's kill is kept.
    func test_aRunStoppedWhileRunningItsTimeoutsAgain_testsOnlyThoseNotRunAgain() async throws {
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree, workers: 4),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .failed, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .timeout, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", rerun: rerun),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", recorded: 5),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        let changes = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.retestedBecause, [.timeoutNotRerun: 1])
        XCTAssertEqual(summary.reused, 3)
        XCTAssertEqual(
            ioDelegate.testLogs.filter { $0.contains("RelationalOperatorReplacement") },
            [running("3_Total.swift_RelationalOperatorReplacement_80_8_5.log")]
        )
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.path), ["Sources/Total.swift"])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
    }

    // A resume under a longer limit than the first session's, which `ResumeCheck` let through, tests its timeout
    // again, and keeps its other results: they ended in time under the shorter one.
    func test_aLongerLimit_testsOnlyTheTimeoutsAgain() async throws {
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree, timeoutSeconds: 60),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .failed, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        state.muterConfiguration = state.muterConfiguration.overriding(workers: nil, timeout: 120)
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let sent = recordEvents(named: [.resumePlanned])

        let changes = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.retestedBecause, [.timeoutUnderShorterLimit: 1])
        XCTAssertEqual(summary.reused, 3)
        XCTAssertEqual(ioDelegate.configurations.last?.testSuiteTimeout, 120)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.path), ["Sources/Total.swift"])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.timeoutSeconds, 120)
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .failed])
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
            Set(ioDelegate.testLogs.dropFirst(3)),
            [
                running("1_Quotient.swift_RelationalOperatorReplacement_40_4_5.log"),
                running("3_Total.swift_RelationalOperatorReplacement_80_8_5.log"),
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
        let sent = recordEvents(named: [.resumePlanned, .mutationTestingStarted, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            sent().prefix(3).map(\.name),
            [.resumePlanned, .mutationTestingStarted, .newTestLogAvailable]
        )
        XCTAssertEqual(
            sent().first?.object as? ResumeSummary,
            ResumeSummary(
                path: resultsPath,
                reused: 2,
                toTest: 2,
                retestedBecause: [.buildError: 1, .notRecorded: 1],
                noLongerDiscovered: 1,
                discoveredBefore: 5,
                coverageChange: nil,
                forced: ["toolchain.testCommandVersion"],
                waived: ["README.md"],
                notices: ["mutationTestWorkers was 4 and is 1 now, which no result depends on."]
            )
        )
        let baselineLog = try XCTUnwrap(sent().dropFirst(2).first?.object as? MutationTestLog)
        XCTAssertNil(baselineLog.mutationPoint)
        XCTAssertEqual(baselineLog.remainingMutationPointsCount, 2)
    }

    // Gone.swift's kill no longer counts, as this session doesn't discover its mutant: the stopped run couldn't gather
    // coverage, which now leaves Gone.swift out.
    func test_theSummary_countsTheResultsNoLongerDiscovered_andSaysHowCoverageChanged() async throws {
        state.projectCoverage = .make(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.noLongerDiscovered, 1)
        XCTAssertEqual(summary.discoveredBefore, 5)
        XCTAssertEqual(summary.discovered, 4)
        XCTAssertEqual(summary.coverageChange, .gatheredOnlyNow)
    }

    // A sample that no longer takes Gone.swift's mutant after a change: the mutant is still discovered, only not
    // sampled, so its result is counted apart, not warned of as gone.
    func test_theSummary_countsTheResultsOutsideTheSample_apartFromThoseNoLongerDiscovered() async throws {
        let gone = record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d").key
        state.apply([.sampleLeftOut([gone])])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.outsideTheSample, 1)
        XCTAssertEqual(summary.noLongerDiscovered, 0)
        XCTAssertEqual(try resultsFiles.records(ResultsRetired.self).last?.keys.contains(gone), true)
    }

    // Coverage the stopped run recorded as it is now explains nothing: Gone.swift's mutant is gone for another reason.
    func test_theSummary_withTheSameCoverage_saysNoCoverageChange() async throws {
        let gathered = CoverageSummary(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        recorded[0] = ResultsHeader.make(coverage: gathered, mutantsDiscovered: 5, mutantsToTest: 5, project: tree)
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file
        )
        state.projectCoverage = .make(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertNil(summary.coverageChange)
        XCTAssertEqual(summary.noLongerDiscovered, 1)
    }

    // A resume of a test plan's run compares the plan's copy, so what --resume-ignoring let through are its files.
    func test_theSummary_ofATestPlansRun_namesTheCopy() async throws {
        recorded[0] = ResultsHeader.make(mutantsDiscovered: 5, mutantsToTest: 5, project: tree, usingTestPlan: true)
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.testPlanCopy, state.mutatedProjectDirectoryURL.path)
        XCTAssertEqual(summary.waived, ["README.md"])
    }

    // xcodebuild names the files without coverage by their path in the copy, which moved with the project: the stopped
    // run was in another CI agent's checkout. They are the same files.
    func test_theSummary_ofAProjectThatMoved_comparesTheFilesWithoutCoverageInEachCopy() async throws {
        recorded[0] = ResultsHeader.make(
            projectPath: "/agent1/project",
            mutatedProjectPath: "/agent1/project_mutated",
            coverage: CoverageSummary(
                percent: 80,
                filesWithoutCoverage: ["/agent1/project_mutated/Sources/Gone.swift"]
            ),
            mutantsDiscovered: 5,
            mutantsToTest: 5,
            project: tree
        )
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file
        )
        state.projectCoverage = .make(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertNil(summary.coverageChange)
    }

    // The reporter gets every outcome the report covers, so the Xcode format warns of the kept survivor too. Only the
    // tested mutants send a log, which moves the progress bar and is kept in the session's log folder.
    func test_reusedOutcomesReachTheXcodeReporter_butNoTestLogIsSent() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let outcomes = recordEvents(named: [.newMutationTestOutcomeAvailable])
        let testLogs = recordEvents(named: [.newTestLogAvailable])

        _ = try await sut.run(with: state)

        let sent = outcomes().compactMap { $0.object as? MutationTestOutcome.Mutation }
        XCTAssertEqual(sent.map(\.point.position.line), [7, 3, 4, 8], "the kept ones first, then each as it is tested")
        XCTAssertEqual(sent.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
        XCTAssertEqual(
            testLogs().map { ($0.object as? MutationTestLog)?.mutationPoint?.position.line },
            [nil, 4, 8],
            "the baseline's, then the tested mutants'"
        )
    }

    // The progress lines count each outcome sent after the baseline's log, which starts them, so the kept results
    // come before it. After it, each tested mutant's outcome comes before its log.
    func test_keptOutcomes_comeBeforeTheBaselinesLog() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.newMutationTestOutcomeAvailable, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            sent().map { $0.name == .newTestLogAvailable ? "log" : "outcome" },
            ["outcome", "outcome", "log", "outcome", "log", "outcome", "log"]
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
        whenSent(.mutationTestingEndedEarly) { event in
            if let earlyEnd = event.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await sut.runInItsOwnTask(with: state)

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
        let calls = Locked(0.0)
        current.now = {
            calls.change { count in
                count += 1
                return ResultsHeader.fixedStart.addingTimeInterval(count * 2.5)
            }
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
        whenSent(.mutationTestingEndedEarly) { event in
            if let earlyEnd = event.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(earlyEnds.map(\.outcome.testDuration), [100.5 + end.testDurationSeconds])
    }

    // What was checked before the copy is what is recorded, and the provenance isn't probed again.
    func test_forcedWaivedAndProvenance_comeFromTheResumeState() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let probed = Locked(0)
        current.provenance = { _ in
            probed.change { $0 += 1 }
            return .fixture
        }

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.provenance, checkedProvenance)
        XCTAssertEqual(header.forced, ["toolchain.testCommandVersion"])
        XCTAssertEqual(header.waived, ["README.md"])
        XCTAssertEqual(probed.value, 0)
    }

    // `swift-mutator report` reads the whole file: the stopped run's lines, then this session's. The kept results come
    // from the earlier session's lines, and the rest from this one's.
    func test_aResumedReport_equalsTheReportFromTheFile() async throws {
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
            return XCTFail("Expected an outcome, got \(changes)")
        }
        let file = try resultsFileData(recorded) + Data(resultsFiles.lines.map { $0 + "\n" }.joined().utf8)
        let fromTheFile = try RecordedResults.read(file, path: resultsPath)
            .mutationTestOutcome(resultsFile: resultsPath)
        XCTAssertEqual(fromTheFile, outcome)
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
    }
}

private extension PerformMutationTestingResumeTests {
    /// The events sent with any of `names` so far, in order.
    func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        for name in names {
            whenSent(name) { sent.append($0) }
        }
        return { sent }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The stopped run's record of the mutant `makeSchemataMapping(file:line:)` makes, as it wrote it, naming
    /// `killedBy` as the tests that failed.
    func record(
        of file: String,
        line: Int,
        _ outcome: TestSuiteOutcome,
        fileSHA256: String,
        killedBy: [FailedTestLine.FailedTest]? = nil,
        rerun: MutantResult.Rerun? = nil
    ) -> MutantResult {
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
            killedBy: killedBy,
            fileSHA256: fileSHA256,
            rerun: rerun
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

    /// Where a test run whose log is `name` writes its output: in the log folder's `running` folder.
    func running(_ name: String) -> String {
        "/project_muter_logs/session 2/running/\(name)"
    }
}
