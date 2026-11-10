@testable import muterCore
import XCTest

extension RecordedResultsStatusTests {
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
