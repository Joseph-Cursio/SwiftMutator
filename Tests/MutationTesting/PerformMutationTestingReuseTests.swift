@testable import muterCore
import TestingExtensions
import XCTest

/// What a run that reuses an earlier run's results (`--reuse`) writes, and the outcome it reports: a results file of
/// its own, which starts with the results it keeps, each with where it was tested, and then those it tests.
final class PerformMutationTestingReuseTests: MuterTestCase {
    let state = MutationTestState()
    let earlierPath = "/project_muter_logs/earlier/results.jsonl"
    let tree = ProjectTree(
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
    /// The test the earlier run recorded failing for Sum.swift's mutant.
    let sumTest = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
    /// What the earlier run recorded: a survivor and a kill that still hold, a build error and a timeout, which a reuse
    /// tests again, and a kill of a mutant this run no longer discovers.
    lazy var recorded: [any Encodable] = [
        ResultsHeader.make(
            mutantsDiscovered: 5,
            mutantsToTest: 5,
            project: tree,
            logDirectory: "/project_muter_logs/earlier"
        ),
        record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
        record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d"),
        record(of: "Sources/Quotient.swift", line: 4, .buildError, fileSHA256: "3c4f"),
        record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
        record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
        ResultsEnd.make(testDurationSeconds: 100.5, recorded: 5),
    ]

    let keepingAllLogs = MuterConfiguration(
        executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: .enabled
    )

    lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, count in
            Array(repeating: URL(fileURLWithPath: "/project_mutated_worker1"), count: count)
        },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/project_muter_logs/now"
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.projectTree = tree
        state.mutationMapping = try [
            makeSchemataMapping(file: "Sources/Product.swift", line: 7),
            makeSchemataMapping(file: "Sources/Quotient.swift", line: 4),
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
            makeSchemataMapping(file: "Sources/Total.swift", line: 8),
        ]
        state.runOptions = .make(reuseURL: URL(fileURLWithPath: earlierPath))
        try reuse(recorded)
    }

    // A reused line says which tests failed in its first run, for their reach, but nothing of what they did alone on
    // code that may have changed, as a reused run's control runs don't count. Nor is a reused kill tested again.
    func test_aReuse_keepsAKillTestedAlone_withoutWhatItsTestsDid() async throws {
        let alone = MutantResult.Rerun(
            because: MutantResult.Rerun.onlySuspectTestsFailed,
            workers: 1,
            alone: [.init(name: "sum()", file: "SumTests.swift", result: MutantResult.TestAlone.failedAgain)]
        )
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], suspectTestFilePercent: 1, suspectTestMinimumFiles: 1
        )
        try reuse([
            ResultsHeader.make(
                mutantsDiscovered: 2,
                mutantsToTest: 2,
                project: tree,
                logDirectory: "/project_muter_logs/earlier"
            ),
            record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest], rerun: alone),
            ResultsEnd.make(testDurationSeconds: 100.5, recorded: 1),
        ])
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .passed]

        let changes = try await sut.run(with: state)

        let kept = try XCTUnwrap(resultsFiles.records(MutantResult.self).first { $0.path == "Sources/Sum.swift" })
        XCTAssertEqual(kept.rerun?.because, MutantResult.Rerun.onlySuspectTestsFailed)
        XCTAssertEqual(kept.rerun?.alone?.map(\.name), ["sum()"])
        XCTAssertEqual(kept.rerun?.alone?.map(\.result), [nil])
        XCTAssertFalse(ioDelegate.testLogs.contains { $0.contains("_rerun_") }, "\(ioDelegate.testLogs)")
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(KillingTestSummary(of: outcome.mutations)?.killsTestedAlone, 0)
    }

    // The earlier file is only read: the run's own file is made in its log folder, as a first session's is, and holds
    // the kept results right after its header, before those it tests.
    func test_aReuse_writesAFileOfItsOwn_startingWithTheResultsItKeeps() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var announced: [String] = []
        whenSent(.resultsFileCreated) { announced.append(($0.object as? String) ?? "") }

        _ = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.resumedPaths, [])
        XCTAssertEqual(resultsFiles.directories, ["/project_muter_logs/now"])
        XCTAssertEqual(announced, ["/project_muter_logs/now/results.jsonl"])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "mutant", "mutant", "end"])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.session, 1)
        XCTAssertEqual(header.formatVersion, ResultsCoding.omittedLogsFormatVersion, "its kills may keep no log")
        XCTAssertEqual(header.reusedFrom, earlierPath)
        XCTAssertEqual(header.mutantsReused, 2)
        XCTAssertEqual(header.mutantsToTest, 2)
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(
            mutants.map(\.path),
            ["Sources/Product.swift", "Sources/Sum.swift", "Sources/Quotient.swift", "Sources/Total.swift"]
        )
        XCTAssertEqual(mutants.map(\.session), [1, 1, 1, 1])
        let origin = ReusedFrom(resultsFile: earlierPath, session: 1, despiteChanges: false)
        XCTAssertEqual(mutants.map(\.reusedFrom), [origin, origin, nil, nil])
        XCTAssertEqual(mutants[1].killedBy, [sumTest], "how it was tested is as recorded")
        XCTAssertEqual(mutants.map { $0.log != nil }, [true, false, true, true], "but for its log, by this run's rule")
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [4], "every mutant line it wrote")
        XCTAssertNil(
            fileManager.createdFiles["/project_muter_logs/now/\(ResultsFile.noteFileName)"],
            "its folder holds its own file, so it leaves no note"
        )
    }

    // Its test duration is its own: the earlier run's isn't in this file.
    func test_aReuse_doesntAddTheEarlierRunsTestDuration() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertLessThan(outcome.testDuration, 100)
    }

    // Each kept result's log is copied into this run's folder under its own name, so the folder stands alone. A kill
    // by a test its line names keeps none, as this run would keep none for it, so its log isn't carried forward.
    func test_aReuse_copiesTheKeptResultsLogs_intoItsOwnFolder() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let copied = fileManager.copyPaths.filter { $0.source.hasPrefix("/project_muter_logs/earlier/") }
        XCTAssertEqual(
            copied.map(\.source), ["/project_muter_logs/earlier/RelationalOperatorReplacement @ Sum.swift-7-5.log"]
        )
        XCTAssertEqual(
            copied.map(\.dest), ["/project_muter_logs/now/RelationalOperatorReplacement @ Sum.swift-7-5.log"]
        )
    }

    // With `keepAllLogs`, every kept result's log is copied, the kill's too.
    func test_aReuseKeepingAllLogs_copiesEveryKeptResultsLog() async throws {
        state.muterConfiguration = keepingAllLogs
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let copied = fileManager.copyPaths.filter { $0.source.hasPrefix("/project_muter_logs/earlier/") }
        XCTAssertEqual(copied.map(\.source), [
            "/project_muter_logs/earlier/RelationalOperatorReplacement @ Sum.swift-7-5.log",
            "/project_muter_logs/earlier/RelationalOperatorReplacement @ Sum.swift-3-5.log",
        ])
        XCTAssertEqual(copied.map(\.dest), [
            "/project_muter_logs/now/RelationalOperatorReplacement @ Sum.swift-7-5.log",
            "/project_muter_logs/now/RelationalOperatorReplacement @ Sum.swift-3-5.log",
        ])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.formatVersion, ResultsCoding.formatVersion, "every line it writes names a log")
    }

    // An earlier run that kept no log for its kill leaves its line with none, which this run copies as it is, so the
    // new file needs format 4 though this run keeps every log it makes. Nothing is copied for it.
    func test_aReuseKeepingAllLogs_ofResultsWithoutALog_isInFormat4() async throws {
        state.muterConfiguration = keepingAllLogs
        var lines = recorded
        lines[0] = ResultsHeader.make(
            formatVersion: ResultsCoding.omittedLogsFormatVersion,
            mutantsDiscovered: 5,
            mutantsToTest: 5,
            project: tree,
            logDirectory: "/project_muter_logs/earlier"
        )
        lines[4] = record(
            of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest], keptLog: false
        )
        try reuse(lines)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.formatVersion, ResultsCoding.omittedLogsFormatVersion)
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.path)[1], "Sources/Sum.swift")
        XCTAssertNil(mutants[1].log)
        XCTAssertEqual(
            fileManager.copyPaths.map(\.source).filter { $0.hasPrefix("/project_muter_logs/earlier/") },
            ["/project_muter_logs/earlier/RelationalOperatorReplacement @ Sum.swift-7-5.log"]
        )
    }
}
