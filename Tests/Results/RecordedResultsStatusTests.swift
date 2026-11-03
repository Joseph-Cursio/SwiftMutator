@testable import muterCore
import XCTest

final class RecordedResultsStatusTests: XCTestCase {
    private let path = "/logs/results.jsonl"
    private let header = ResultsHeader.make(mutantsDiscovered: 3)
    private let sum = MutantResult.make(path: "Sources/Sum.swift")
    private let product = MutantResult.make(path: "Sources/Product.swift")

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
                "One mutant tested with --mutant (\(key)): its score isn't the project's.",
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

    func test_aSingleSession_andAnEmptyReport_sayNothingMore() throws {
        let single = try read(file(header, sum, product, ResultsEnd.make()))
        let empty = try read(file(header, ResultsEnd.make(reason: .interrupted), ResultsHeader.make(session: 2)))

        XCTAssertNil(single.resultSources)
        XCTAssertNil(empty.resultSources)
        XCTAssertEqual(
            empty.statusLines(path: path),
            [
                "Report of 0 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }

    func test_severalSessions_areCountedEach_leavingOutThoseWithNoResultLeft() throws {
        let second = ResultsHeader.make(session: 2)
        let third = ResultsHeader.make(session: 3)
        let quotient = MutantResult.make(session: 2, path: "Sources/Quotient.swift")
        let difference = MutantResult.make(session: 3, path: "Sources/Difference.swift")

        let three = try read(file(header, sum, product, second, quotient, third, difference))
        let middleLeftNothing = try read(file(header, sum, product, second, third, difference))

        XCTAssertEqual(
            three.resultSources,
            "Of these, 1 was tested in the last session, session 3, and 3 in earlier ones (2 in session 1 and 1 in "
                + "session 2)."
        )
        XCTAssertEqual(
            middleLeftNothing.resultSources,
            "Of these, 1 was tested in the last session, session 3, and 2 in session 1."
        )
    }

    func test_aResultTestedAgain_countsForTheLaterSession() throws {
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .passed)

        let recorded = try read(
            file(
                header,
                sum,
                product,
                ResultsHeader.make(session: 2),
                ResultsRetired(session: 2, keys: [sum.key]),
                retested
            )
        )

        XCTAssertEqual(
            recorded.resultSources,
            "Of these, 1 was tested in the last session, session 2, and 1 in session 1."
        )
    }

    // A timeout tested again at lower load is one result, as the report has it.
    func test_aRerun_countsOnce() throws {
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        let quotient = MutantResult.make(
            session: 2, path: "Sources/Quotient.swift", outcome: .timeout, endedBy: .timedOut
        )
        let quotientRerun = MutantResult.make(session: 2, path: quotient.path, outcome: .passed, rerun: rerun)

        // One session that kept a result: counted by line, the timeout and its rerun would be "2 were tested".
        let timedOut = MutantResult.make(path: quotient.path, outcome: .timeout, endedBy: .timedOut)
        let timedOutRerun = MutantResult.make(path: quotient.path, outcome: .passed, rerun: rerun)
        let reused = try read(
            file(ResultsHeader.make(reusedFrom: older), kept(sum, from: older), timedOut, timedOutRerun)
        )
        let resumed = try read(file(header, sum, ResultsHeader.make(session: 2), quotient, quotientRerun))

        XCTAssertEqual(
            reused.resultSources,
            "Of these, 1 was tested and 1 kept by --reuse, tested in /logs/Oct 31, 2026 at 7:08 PM/results.jsonl."
        )
        XCTAssertEqual(
            resumed.statusLines(path: path),
            [
                "Report of 2 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
                "Of these, 1 was tested in the last session, session 2, and 1 in session 1.",
            ]
        )
    }

    // Each by the file it was first tested in. A log folder's name holds commas, so the path comes last in its phrase.
    func test_reusedResults_areCountedByTheFileTheyWereTestedIn() throws {
        let reusing = ResultsHeader.make(reusedFrom: older)
        let quotient = MutantResult.make(path: "Sources/Quotient.swift")

        let oneFile = try read(file(reusing, kept(sum, from: older), kept(product, from: older), quotient))
        let twoFiles = try read(file(reusing, kept(sum, from: older), kept(product, from: oldest), quotient))
        let nothingTested = try read(file(reusing, kept(sum, from: older)))

        XCTAssertEqual(
            oneFile.resultSources,
            "Of these, 1 was tested and 2 kept by --reuse, tested in /logs/Oct 31, 2026 at 7:08 PM/results.jsonl."
        )
        XCTAssertEqual(
            twoFiles.resultSources,
            "Of these, 1 was tested and 2 kept by --reuse (1 tested in /logs/Oct 30, 2026 at 9:15 AM/results.jsonl "
                + "and 1 in /logs/Oct 31, 2026 at 7:08 PM/results.jsonl)."
        )
        XCTAssertEqual(
            nothingTested.resultSources,
            "Of these, none were tested and 1 kept by --reuse, tested in /logs/Oct 31, 2026 at 7:08 PM/results.jsonl."
        )
    }

    func test_aReuseResumed_countsEachSession_andWhatItKept() throws {
        let quotient = MutantResult.make(session: 2, path: "Sources/Quotient.swift")

        let recorded = try read(
            file(
                ResultsHeader.make(reusedFrom: older),
                kept(sum, from: older),
                product,
                ResultsEnd.make(reason: .interrupted),
                ResultsHeader.make(session: 2, mutantsReused: 2),
                quotient
            )
        )

        XCTAssertEqual(
            recorded.resultSources,
            "Of these, 1 was tested in the last session, session 2, 1 in session 1, and 1 kept by --reuse, tested in "
                + "/logs/Oct 31, 2026 at 7:08 PM/results.jsonl."
        )
    }

    // In a file SwiftMutator wrote whole, what the earlier sessions tested is what the last one's header kept.
    func test_theEarlierSessionsCount_agreesWithMutantsReused() throws {
        let resumed = ResultsHeader.make(
            formatVersion: ResultsCoding.resumedFormatVersion, session: 2, mutantsReused: 1
        )
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .passed)
        let quotient = MutantResult.make(session: 2, path: "Sources/Quotient.swift")

        let recorded = try read(
            file(
                header,
                sum,
                product,
                ResultsEnd.make(reason: .interrupted),
                resumed,
                ResultsRetired(session: 2, keys: [sum.key]),
                retested,
                quotient
            )
        )

        XCTAssertEqual(recorded.headers.last?.mutantsReused, 1)
        XCTAssertEqual(
            recorded.resultSources,
            "Of these, 2 were tested in the last session, session 2, and 1 in session 1."
        )
    }

    // Killed between its header and its retired line, a session leaves the results it meant to test again in the
    // report, which counts them for the session that tested them.
    func test_aSessionWithoutItsRetiredLine_countsWhatTheReportShows() throws {
        let resumed = ResultsHeader.make(
            formatVersion: ResultsCoding.resumedFormatVersion, session: 2, mutantsReused: 1
        )

        let recorded = try read(file(header, sum, product, ResultsEnd.make(reason: .interrupted), resumed))

        XCTAssertEqual(
            recorded.resultSources,
            "Of these, none were tested in the last session, session 2, and 2 in session 1."
        )
    }
}

private extension RecordedResultsStatusTests {
    var older: String {
        "/logs/Oct 31, 2026 at 7:08 PM/results.jsonl"
    }

    var oldest: String {
        "/logs/Oct 30, 2026 at 9:15 AM/results.jsonl"
    }

    /// `result`, as a session that reused it from the results file at `resultsFile` writes it.
    func kept(_ result: MutantResult, from resultsFile: String) -> MutantResult {
        var copy = result
        copy.reusedFrom = ReusedFrom(resultsFile: resultsFile, session: 1, despiteChanges: false)
        return copy
    }

    func read(_ data: Data) throws -> RecordedResults {
        try RecordedResults.read(data, path: path)
    }

    func line(_ record: some Encodable) throws -> Data {
        try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
    }

    func file(_ records: any Encodable...) throws -> Data {
        try records.reduce(into: Data()) { data, record in data += try line(record) }
    }
}
