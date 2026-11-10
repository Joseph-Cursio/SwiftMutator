@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingResumeTests {
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
}
