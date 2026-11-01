@testable import muterCore
import TestingExtensions
import XCTest

/// What a run that reuses an earlier run's results (`--reuse`) writes, and the outcome it reports: a results file of
/// its own, which starts with the results it keeps, each with where it was tested, and then those it tests.
final class PerformMutationTestingReuseTests: MuterTestCase {
    private let state = MutationTestState()
    private let earlierPath = "/project_muter_logs/earlier/results.jsonl"
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
    /// The test the earlier run recorded failing for Sum.swift's mutant.
    private let sumTest = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
    /// What the earlier run recorded: a survivor and a kill that still hold, a build error and a timeout, which a reuse
    /// tests again, and a kill of a mutant this run no longer discovers.
    private lazy var recorded: [any Encodable] = [
        ResultsHeader.make(mutantsDiscovered: 5, mutantsToTest: 5, project: tree, logDirectory: "/project_muter_logs/earlier"),
        record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
        record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d"),
        record(of: "Sources/Quotient.swift", line: 4, .buildError, fileSHA256: "3c4f"),
        record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
        record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
        ResultsEnd.make(testDurationSeconds: 100.5, recorded: 5),
    ]

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, count in Array(repeating: URL(fileURLWithPath: "/project_mutated_worker1"), count: count) },
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
        XCTAssertEqual(header.formatVersion, ResultsCoding.formatVersion)
        XCTAssertEqual(header.reusedFrom, earlierPath)
        XCTAssertEqual(header.mutantsReused, 2)
        XCTAssertEqual(header.mutantsToTest, 2)
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.path), ["Sources/Product.swift", "Sources/Sum.swift", "Sources/Quotient.swift", "Sources/Total.swift"])
        XCTAssertEqual(mutants.map(\.session), [1, 1, 1, 1])
        let origin = ReusedFrom(resultsFile: earlierPath, session: 1, despiteChanges: false)
        XCTAssertEqual(mutants.map(\.reusedFrom), [origin, origin, nil, nil])
        XCTAssertEqual(mutants[1].killedBy, [sumTest], "how it was tested is as recorded")
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [4], "every mutant line it wrote")
    }

    // Its test duration is its own: the earlier run's isn't in this file.
    func test_aReuse_doesntAddTheEarlierRunsTestDuration() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertLessThan(outcome.testDuration, 100)
    }

    // Each kept result's log is copied into this run's folder under its own name, so the folder stands alone.
    func test_aReuse_copiesTheKeptResultsLogs_intoItsOwnFolder() async throws {
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
    }

    // `swift-mutator report` of the new file alone gives the run's own report, the reused results marked.
    func test_theReportFromTheNewFile_equalsTheRunsOwn_withTheReusedResultsMarked() async throws {
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
        let file = Data(resultsFiles.lines.map { $0 + "\n" }.joined().utf8)
        let fromTheFile = try RecordedResults.read(file, path: "/project_muter_logs/now/results.jsonl")
            .mutationTestOutcome()
        XCTAssertEqual(fromTheFile, outcome)
        XCTAssertEqual(outcome.mutations.map { $0.reusedFrom != nil }, [true, false, true, false])
    }

    // What a waiver or a force let through marks every result kept, so the reports can say so.
    func test_resultsKeptDespiteAWaiverOrAForce_areMarked() async throws {
        state.resumeWaived = ["README.md"]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let kept = try resultsFiles.records(MutantResult.self).compactMap(\.reusedFrom)
        XCTAssertEqual(kept.map(\.despiteChanges), [true, true])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.waived, ["README.md"])
    }

    // With every result kept and nothing changed, there is nothing to test, and no baseline to run.
    func test_withNothingToTest_andNothingChanged_runsNoBaseline() async throws {
        try reuse(heldEverywhere())

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "mutant", "mutant", "end"])
    }

    // After any change, even one let through, the baseline still runs: a changed test that now fails would otherwise
    // keep every kill. Nothing else does, as nothing is left to test.
    func test_withNothingToTest_afterAChange_runsTheBaselineOnly() async throws {
        try reuse(heldEverywhere(), changes: [.init(path: "README.md", kind: .added)], waiving: ["README.md"])
        state.resumeWaived = ["README.md"]
        ioDelegate.testSuiteOutcomes = [.passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.testLogs, [running("baseline run")])
        XCTAssertEqual(try resultsFiles.kinds(), ["header", "mutant", "mutant", "mutant", "mutant", "end"])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.mutantsToTest, 0)
    }

    // ...and a failing baseline then stops the run, as any run's does.
    func test_withNothingToTest_afterAChange_aFailingBaselineStopsTheRun() async throws {
        try reuse(heldEverywhere(), changes: [.init(path: "README.md", kind: .added)], waiving: ["README.md"])
        ioDelegate.testSuiteOutcomes = [.failed]

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(resultsFiles.lines, [])
    }
}

private extension PerformMutationTestingReuseTests {
    /// Makes `lines` the earlier run's results file, whose only session's tree was this run's, with `changes` from it
    /// to this run's, and `globs` waiving those they match.
    func reuse(
        _ lines: [any Encodable],
        changes fileChanges: [ProjectTree.FileChange] = [],
        waiving globs: [String] = []
    ) throws {
        state.resumeState = try ResumeState.make(path: earlierPath, lines: lines, file: nil)
        var files = tree.files
        for change in fileChanges {
            files[change.path] = change.kind == .removed ? nil : "ffff"
        }
        let earlier = ProjectTree(
            listedBy: .git,
            files: tree.files.filter { path, _ in !fileChanges.contains { $0.path == path && $0.kind == .added } },
            excluded: [],
            treeSHA256: "e5b8"
        )
        let current = ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: "f00d")
        state.reuseChanges = [1: ReuseChanges(from: earlier, to: current, waiving: globs, readSource: { _ in nil })]
    }

    /// An earlier run whose every result this run keeps.
    func heldEverywhere() -> [any Encodable] {
        [
            ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree, logDirectory: "/project_muter_logs/earlier"),
            record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
            record(of: "Sources/Quotient.swift", line: 4, .passed, fileSHA256: "3c4f"),
            record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
            record(of: "Sources/Total.swift", line: 8, .passed, fileSHA256: "9e21"),
            ResultsEnd.make(recorded: 4),
        ]
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// The earlier run's record of the mutant `makeSchemataMapping(file:line:)` makes.
    func record(
        of file: String,
        line: Int,
        _ outcome: TestSuiteOutcome,
        fileSHA256: String,
        killedBy: [FailedTestLine.FailedTest]? = nil
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
            endedBy: outcome == .timeout ? .timedOut : .exited,
            killedBy: killedBy,
            fileSHA256: fileSHA256
        )
    }

    /// A file in the mutated project with one mutant, at `line`, column 5.
    func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/\(file)",
            (
                source: "func bar() { }",
                schemata: [
                    try .make(
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

    /// Where a test run whose log is `name` writes its output: in the log folder's `running` folder.
    func running(_ name: String) -> String {
        "/project_muter_logs/now/running/\(name)"
    }
}
