@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingResumeTests {
    // A kept result's outcome is built from its job, as a tested one's is, and takes its place in job order.
    func test_mergesRecordedAndNewOutcomesInJobOrder() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
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
            XCTFail("Expected an outcome, got \(changes)")
            return
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
            "runTestsWithoutBuilding(using:timeLimit:savingResultsIntoFileNamed:)",
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
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 100.5, recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
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
            XCTFail("Expected an outcome, got \(changes)")
            return
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
            executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: .enabled
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
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", killedBy: [sumTest]),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
            ],
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
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
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .runtimeError, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(reason: .finished, testDurationSeconds: 100.5, recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
        )

        _ = try await sut.run(with: state)
        removeFolderIfEmpty(atPath: folder, fileManager: FileManager.default)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [ResultsFile.noteFileName])
        XCTAssertEqual(try ResultsFile.find(at: folder, using: FileManager.default), resultsPath)
    }
}
