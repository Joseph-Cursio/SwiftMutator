@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingResultsTests {
    func test_whenTheResultsFileCannotBeCreated_theRunGoesOn_andSaysSo() async throws {
        resultsFiles.errorToThrow = ResultsFileError.cannotOpen(path: "/logs/results.jsonl", errno: EACCES)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog]
        let sent = recordEvents(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(sent().map(\.name), [.resultsFileUnavailable])
        XCTAssertEqual(sent().first?.object as? String, "can't open /logs/results.jsonl: Permission denied")
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
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
        let sent = recordEvents(named: [.resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(
            sent().first?.object as? String,
            "can't write to /logs/results.jsonl: No space left on device"
        )
        XCTAssertEqual(try resultsFiles.kinds(), ["header"])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .failed])
        XCTAssertEqual(outcome.mutations.map(\.killingTests), [sumKilled, sumKilled], "worked out after a failed write")
        XCTAssertNil(outcome.run, "the file lacks the results after the failed write, so the reports don't name it")
    }

    // A file without its header isn't a results file, so it isn't announced as one.
    func test_whenTheHeaderCannotBeWritten_theFileIsNotAnnounced_andTheRunGoesOn() async throws {
        resultsFiles.failFromLine = 1
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(sent().map(\.name), [.resultsFileUnavailable])
        XCTAssertEqual(resultsFiles.lines, [])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.count, 2)
    }

    func test_aStateWithoutALogFolder_writesNoResults() async throws {
        state.loggingDirectory = ""
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog]
        let sent = recordEvents(named: [.resultsFileCreated, .resultsFileUnavailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(resultsFiles.directories, [])
        XCTAssertEqual(sent().count, 0)
        XCTAssertEqual(
            try XCTUnwrap(outcome(of: changes)).mutations.first?.killingTests,
            sumKilled,
            "worked out without a results file"
        )
    }
}
