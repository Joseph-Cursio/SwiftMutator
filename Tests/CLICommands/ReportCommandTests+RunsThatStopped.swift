import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    // A script that checks the report fails as one that checked the run would: the run exited 4 for its abort. The
    // report and the status are still given first, and ArgumentParser prints nothing more.
    func test_aRunThatStoppedOnAnError_isReported_thenExitsAsTheRunDid() async throws {
        let end = ResultsEnd.make(reason: .aborted, detail: "mutantNotSwitchedOn")
        try write(ResultsHeader.make(), alpha3, end, to: resultsPath)

        await AssertThrowsError(try await report(resultsPath)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 4)
            XCTAssertEqual(MuterCommand.fullMessage(for: error), "")
        }
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 1 of 3 mutants, from \(resultsPath): the run stopped on an error (mutantNotSwitchedOn)."]
        )
    }

    // Only an error: a run that was interrupted, or has no end line yet, says nothing about its mutants' code.
    func test_aRunThatWasInterrupted_orHasNoEndLine_exits0() async throws {
        for end in [ResultsEnd.make(reason: .interrupted, detail: "SIGINT"), nil] {
            try write([ResultsHeader.make(), alpha3] + [end].compactMap(\.self), to: resultsPath)

            try await report(resultsPath)
        }

        XCTAssertEqual(printer.linesPassed.count, 2)
    }

    // The run is still going, or was killed or crashed: the report holds what it had tested.
    func test_aFileWithoutAnEndLine_isReported_sayingSo() async throws {
        try write(ResultsHeader.make(), alpha3, to: resultsPath)

        try await report(resultsPath)

        let soFar = ran(MutationTestOutcome(
            mutations: [mutation("Sources/Alpha.swift", line: 3, .failed)],
            coverageSkipped: true,
            testDuration: 31.25
        ))
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: soFar)])
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 1 of 3 mutants, from \(resultsPath): "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }
}
