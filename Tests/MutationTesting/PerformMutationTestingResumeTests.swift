@testable import muterCore
import TestingExtensions
import XCTest

/// What a resumed run's mutation testing writes to the stopped run's results file, and the outcome it reports: it tests
/// only the mutants without a recorded result that still holds, and reports those it keeps with them, in job order.
final class PerformMutationTestingResumeTests: MuterTestCase {
    let state = MutationTestState()
    let resultsPath = "/project_muter_logs/session 1/results.jsonl"
    /// The note this session leaves in its own log folder, naming the file.
    let notePath = "/project_muter_logs/session 2/resumed session.txt"
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    var clonedCounts: [Int] = []
    private static let files = [
        "Sources/Product.swift": "77e0",
        "Sources/Quotient.swift": "3c4f",
        "Sources/Sum.swift": "5a1c",
        "Sources/Total.swift": "9e21",
    ]
    /// With its real `treeSHA256`, which a resumed header's `projectDelta` is read back against.
    let tree = ProjectTree(
        listedBy: .git,
        files: files,
        excluded: [],
        treeSHA256: ProjectTree.treeHash(of: files)
    )
    /// The test the stopped run recorded failing for Sum.swift's mutant.
    let sumTest = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
    /// What the stopped run's only session recorded: a survivor and a kill that still hold, a build error, which is
    /// tested again, and a kill of a mutant this run no longer discovers. It never got to Total.swift's mutant.
    lazy var recorded: [any Encodable] = [
        ResultsHeader.make(mutantsDiscovered: 5, mutantsToTest: 5, project: tree),
        record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
        record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d"),
        record(of: "Sources/Quotient.swift", line: 4, .buildError, fileSHA256: "3c4f"),
        record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
        ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 4),
    ]
    /// The provenance probed before the copy, which differs from the one `current.provenance` gives.
    let checkedProvenance = Provenance(
        swiftMutator: .init(version: "1.0.0", executablePath: "/usr/local/bin/swift-mutator", executableSHA256: "4d1e"),
        toolchain: .init(testCommandVersion: "Apple Swift version 6.5", testExecutableSHA256: nil, environment: [:]),
        processIdentifier: 90_210,
        host: "studio.local",
        arguments: ["--resume", "results.jsonl", "--force-resume"]
    )

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [weak self] _, count in
            guard let self else { return [] }
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
        XCTAssertEqual(reruns.first?.contains("Product.swift"), true, "\(reruns)")
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

        let note = try XCTUnwrap(fileManager.createdFiles[notePath].map { String(lossyUTF8: $0) })
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
}
