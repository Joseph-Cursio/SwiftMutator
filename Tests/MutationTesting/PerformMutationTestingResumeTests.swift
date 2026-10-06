@testable import muterCore
import TestingExtensions
import XCTest

/// What a resumed run's mutation testing writes to the stopped run's results file, and the outcome it reports. Until
/// recorded results are reused, it tests every mutant again.
final class PerformMutationTestingResumeTests: MuterTestCase {
    private let state = MutationTestState()
    private let resultsPath = "/project_muter_logs/session 1/results.jsonl"
    private let tree = ProjectTree(
        listedBy: .git,
        files: ["Sources/Product.swift": "77e0", "Sources/Sum.swift": "5a1c"],
        excluded: [],
        treeSHA256: "e5b8"
    )
    /// What the stopped run's only session recorded: a survivor and a kill of the two mutants this run discovers, and
    /// a kill of one it no longer does.
    private lazy var recorded: [any Encodable] = [
        ResultsHeader.make(mutantsDiscovered: 3, mutantsToTest: 3, project: tree),
        MutantResult.make(path: "Sources/Product.swift", line: 7, column: 5, outcome: .passed, fileSHA256: "77e0"),
        MutantResult.make(path: "Sources/Gone.swift", line: 2, column: 5, outcome: .failed, fileSHA256: "0b9d"),
        MutantResult.make(path: "Sources/Sum.swift", line: 3, column: 5, outcome: .failed, fileSHA256: "5a1c"),
        ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 3),
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
        makeWorkerDirectories: { _, count in
            Array(repeating: URL(fileURLWithPath: "/project_mutated_worker1"), count: count)
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
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
        ]
        state.resumeWaived = ["README.md"]
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: recorded,
            file: resultsFiles.openForResume(at: resultsPath),
            provenance: checkedProvenance,
            forced: ["toolchain.testCommandVersion"]
        )
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
        XCTAssertEqual(header.mutantsDiscovered, 2)
        XCTAssertEqual(header.mutantsToTest, 2)
        XCTAssertEqual(header.mutantsReused, 0)
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

    // Every mutant is tested again, so no earlier result stands, not even one of a mutant no longer discovered.
    func test_theRetiredLine_listsEveryRecordedKey() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let retired = try resultsFiles.records(ResultsRetired.self)
        XCTAssertEqual(retired.map(\.session), [2])
        XCTAssertEqual(
            retired.first?.keys,
            [
                MutantKey(path: "Sources/Gone.swift", mutationOperatorId: .ror, line: 2, column: 5, occurrence: 0),
                MutantKey(path: "Sources/Product.swift", mutationOperatorId: .ror, line: 7, column: 5, occurrence: 0),
                MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 5, occurrence: 0),
            ]
        )
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

    // `swift-mutator report` reads the whole file: the stopped run's lines, then this session's.
    func test_theReportFromTheFile_equalsTheRunsOwn() async throws {
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
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
    }
}

private extension PerformMutationTestingResumeTests {
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
