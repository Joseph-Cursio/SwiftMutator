@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    func test_acceptsARunsLogFolder() throws {
        let folder = "\(directory)/project_muter_logs/Oct 4, 2026 at 1:16 PM"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "a mutant's test log".write(
            toFile: "\(folder)/RelationalOperatorReplacement @ Sum.swift-73-22.log", atomically: true, encoding: .utf8
        )
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: "\(folder)/results.jsonl")

        try report(folder)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: ["\(folder)/results.jsonl"]))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(folder)/results.jsonl: the run finished."]
        )
    }

    // A resumed session's folder holds no results file but a note naming the one it adds to, in the first session's.
    func test_acceptsAResumedSessionsLogFolder() throws {
        let (first, resumed) = try makeAResumedRunsLogFolders()

        try report(resumed)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: ["\(first)/results.jsonl"]))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(first)/results.jsonl: the run finished."]
        )
    }

    func test_aResumedRunsFile_saysWhichSessionsTestedItsResults() throws {
        let resumed = ResultsHeader.make(
            formatVersion: ResultsCoding.resumedFormatVersion, session: 2, mutantsReused: 1
        )
        let alpha3Again = MutantResult.make(session: 2, path: "Sources/Alpha.swift", line: 3, outcome: .failed)
        let zeta10Resumed = MutantResult.make(session: 2, path: "Sources/Zeta.swift", line: 10, outcome: .passed)
        try write(
            ResultsHeader.make(),
            zeta9,
            alpha3,
            // The sessions' test durations add up to the 100.5 seconds `expected` has.
            ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 40),
            resumed,
            ResultsRetired(session: 2, keys: [alpha3.key]),
            alpha3Again,
            zeta10Resumed,
            ResultsEnd.make(session: 2, testDurationSeconds: 60.5),
            to: resultsPath
        )

        try report(resultsPath)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: [resultsPath], header: resumed))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 3 of 3 mutants, from \(resultsPath): the run finished.",
                "Of these, 2 were tested in the last session, session 2, and 1 in session 1.",
            ]
        )
    }

    // As a glob over the run's log folders gives them, in any order: one file, reported as it is, not merged.
    func test_aRunsFirstAndResumedFolders_reportItsFileOnce() throws {
        let (first, resumed) = try makeAResumedRunsLogFolders()
        let second = "\(directory)/project_muter_logs/session 3"
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        try writeNote(pointingTo: "\(first)/results.jsonl", session: 3, in: second)

        for folders in [[first, resumed], [resumed, first], [resumed, second], [second, first, resumed]] {
            let printed = printer.linesPassed.count
            let said = standardError.linesPassed.count

            try report(folders)

            XCTAssertEqual(
                Array(printer.linesPassed.dropFirst(printed)),
                [PlainTextReporter().report(from: expected(from: ["\(first)/results.jsonl"]))],
                "\(folders)"
            )
            XCTAssertEqual(
                Array(standardError.linesPassed.dropFirst(said)),
                ["Report of 3 of 3 mutants, from \(first)/results.jsonl: the run finished."],
                "\(folders)"
            )
        }
    }

    // The note spells the file's path as the resume was given it, here through a symbolic link to the logs, and the
    // glob spells it another way.
    func test_aRunsFirstAndResumedFolders_reportItsFileOnce_howeverTheNoteSpellsItsPath() throws {
        let (first, resumed) = try makeAResumedRunsLogFolders()
        let linked = "\(directory)/linked logs"
        try FileManager.default.createSymbolicLink(
            atPath: linked,
            withDestinationPath: "\(directory)/project_muter_logs"
        )
        try writeNote(pointingTo: "\(linked)/session 1/results.jsonl", session: 2, in: resumed)

        try report(first, resumed)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: ["\(first)/results.jsonl"]))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(first)/results.jsonl: the run finished."]
        )
    }

    // Only a file a note names is dropped as a repeat: a shard's file given twice by its own path or folder is still
    // refused, as a mistake in the command.
    func test_aShardsFileGivenTwice_isStillRefused() async throws {
        let (first, resumed) = try makeAResumedRunsLogFolders(header: shardHeader(1, mutantsDiscovered: 2))

        await assertRefused(
            try report(first, first, resumed),
            MergeRefused(reasons: [
                .givenTwice(Shard(index: 1, count: 2), paths: ["\(first)/results.jsonl", "\(first)/results.jsonl"]),
            ])
        )
    }
}
