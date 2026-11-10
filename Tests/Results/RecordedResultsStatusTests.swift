import ArgumentParser
@testable import muterCore
import XCTest

final class RecordedResultsStatusTests: XCTestCase {
    func test_aFinishedRun() throws {
        let recorded = try read(file(header, sum, product, ResultsEnd.make(reason: .finished)))

        XCTAssertEqual(
            recorded.statusLines(path: path),
            ["Report of 2 of 3 mutants, from /logs/results.jsonl: the run finished."]
        )
    }

    func test_anInterruptedRun_namesTheSignal() throws {
        let recorded = try read(file(header, sum, ResultsEnd.make(reason: .interrupted, detail: "SIGINT")))

        XCTAssertEqual(
            recorded.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run was interrupted by SIGINT."]
        )
    }

    func test_anInterruptionWithoutASignal() throws {
        let recorded = try read(file(header, sum, ResultsEnd.make(reason: .interrupted, detail: nil)))

        XCTAssertEqual(
            recorded.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run was interrupted."]
        )
    }

    func test_anAbortedRun_namesTheError() throws {
        let named = try read(file(header, sum, ResultsEnd.make(reason: .aborted, detail: "tooManyBuildErrors")))
        let unnamed = try read(file(header, sum, ResultsEnd.make(reason: .aborted, detail: nil)))

        XCTAssertEqual(
            named.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run stopped on an error (tooManyBuildErrors)."]
        )
        XCTAssertEqual(
            unnamed.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run stopped on an error."]
        )
    }

    func test_aFileWithoutAnEndLine_mayStillBeRunning() throws {
        let someTested = try read(file(header, sum))
        let noneTested = try read(file(header))

        XCTAssertEqual(
            someTested.statusLines(path: path),
            [
                "Report of 1 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
        XCTAssertEqual(
            noneTested.statusLines(path: path),
            [
                "Report of 0 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }

    // Its score is one mutant's, and the outcome its report is made from says which.
    func test_aRunOfOneMutant_saysItsScoreIsntTheProjects() throws {
        let key = "Sources/Sum.swift:3:4 RelationalOperatorReplacement"
        let recorded = try read(
            file(ResultsHeader.make(mutantsDiscovered: 1, mutant: key), sum, ResultsEnd.make(reason: .finished))
        )

        XCTAssertEqual(
            recorded.statusLines(path: path),
            [
                "Report of 1 of 1 mutants, from /logs/results.jsonl: the run finished.",
                "One mutant chosen with --mutant (\(key)): its score isn't the project's.",
            ]
        )
        XCTAssertEqual(recorded.mutationTestOutcome().mutant, key)
        XCTAssertNil(try read(file(header, sum)).mutationTestOutcome().mutant)
    }

    func test_skippedLines_areNumbered_andACutOffLastLineIsSaid() throws {
        let garbled = Data("{\"kind\":\"mutant\",\"pa\n".utf8)
        let oneSkipped = try read(file(header, sum) + garbled + file(ResultsEnd.make()))
        let cutOff = try read(file(header, sum) + garbled + garbled + file(product) + line(product).prefix(40))

        XCTAssertEqual(
            oneSkipped.statusLines(path: path),
            [
                "Report of 1 of 3 mutants, from /logs/results.jsonl: the run finished.",
                "Skipped 1 line that didn't read: 3.",
            ]
        )
        XCTAssertEqual(
            cutOff.statusLines(path: path),
            [
                "Report of 2 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
                "Skipped 3 lines that didn't read: 3, 4, 6; the last was cut off as it was written.",
            ]
        )
    }

    func test_theLastSessionSaysHowTheRunEnded() throws {
        let interrupted = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        let resumed = ResultsHeader.make(session: 2, mutantsDiscovered: 4)
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .passed)
        let quotient = MutantResult.make(session: 2, path: "Sources/Quotient.swift")

        let finished = try read(
            file(header, sum, interrupted, resumed, retested, quotient, ResultsEnd.make(session: 2, reason: .finished))
        )
        let stillRunning = try read(file(header, sum, ResultsEnd.make(reason: .finished), resumed, quotient))

        XCTAssertEqual(
            finished.statusLines(path: path),
            [
                "Report of 2 of 4 mutants, from /logs/results.jsonl: the run finished.",
                "Of these, 2 were tested in the last session, session 2.",
            ]
        )
        XCTAssertEqual(
            stillRunning.statusLines(path: path),
            [
                "Report of 2 of 4 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
                "Of these, 1 was tested in the last session, session 2, and 1 in session 1.",
            ]
        )
    }

    func test_aRetiredKey_isNotCountedAsReported() throws {
        let resumed = ResultsHeader.make(
            formatVersion: ResultsCoding.resumedFormatVersion, session: 2, mutantsDiscovered: 3
        )

        let recorded = try read(
            file(
                header,
                sum,
                product,
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT"),
                resumed,
                ResultsRetired(session: 2, keys: [sum.key]),
                ResultsEnd.make(session: 2, reason: .aborted, detail: "tooManyBuildErrors")
            )
        )

        XCTAssertEqual(
            recorded.statusLines(path: path),
            [
                "Report of 1 of 3 mutants, from /logs/results.jsonl: the run stopped on an error (tooManyBuildErrors).",
                "Of these, none were tested in the last session, session 2, and 1 in session 1.",
            ]
        )
    }

    // `report` exits as the run did: for each kind of abort reason (`RunCommandTests.everyAbortReason` has one of
    // each), as `ExitCode.exitStatus(afterRunFailedWith:)` gives it; 255 for any other error; 0 for a run that didn't
    // stop on one.
    func test_theStatusTheRunExitedWith_followsItsEndLine() throws {
        for (reason, status) in RunCommandTests.everyAbortReason {
            let error = MuterError.mutationTestingAborted(reason: reason)
            let end = ResultsEnd.make(reason: .aborted, detail: ResultsEnd.detail(for: error))
            XCTAssertEqual(end.exitStatus, status, "\(reason)")
            XCTAssertEqual(end.exitStatus, ExitCode.exitStatus(afterRunFailedWith: error), "\(reason)")
            XCTAssertEqual(try read(file(header, sum, end)).exitStatus, status, "\(reason)")
            // The end line's code is the reason's kind, which is how the status is found again.
            XCTAssertEqual(end.detail?.hasPrefix(reason.kind.rawValue), true, "\(reason)")
        }
        for detail in ["MuterError", nil] {
            XCTAssertEqual(ResultsEnd.make(reason: .aborted, detail: detail).exitStatus, .stoppedOnAnError)
        }
        XCTAssertNil(ResultsEnd.make(reason: .finished).exitStatus)
        XCTAssertNil(ResultsEnd.make(reason: .interrupted, detail: "SIGINT").exitStatus)
        XCTAssertNil(try read(file(header, sum)).exitStatus)
    }

    // A run that didn't finish says how many of its mutants have results with its verdict on the score.
    func test_unfinishedProgress_ofARunThatLacksResults() throws {
        XCTAssertNil(try read(file(header, sum, ResultsEnd.make(reason: .finished))).unfinishedProgress)
        XCTAssertEqual(
            try read(file(header, sum, ResultsEnd.make(reason: .interrupted))).unfinishedProgress,
            ScoreGate.Progress(results: 1, discovered: 3)
        )
        XCTAssertEqual(try read(file(header, sum)).unfinishedProgress, ScoreGate.Progress(results: 1, discovered: 3))
        // Stopped after its last mutant's result, so none is missing.
        let third = MutantResult.make(path: "Sources/Third.swift")
        let lastResult = try read(file(header, sum, product, third, ResultsEnd.make(reason: .interrupted)))
        XCTAssertNil(lastResult.unfinishedProgress)
    }
}
