@testable import muterCore
import XCTest

extension ResultsFileTests {
    // A run killed in the middle of a write leaves its last line cut off, and the next session's first line must not
    // join it: both would be lost to readers.
    func test_openForResume_endsACutOffLastLine_soTheNextLineStandsAlone() throws {
        let earlier = try line(header) + line(mutant).prefix(10)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)

        XCTAssertEqual(try contents(of: resultsPath), earlier, "the line is ended only when the session writes one")
        XCTAssertTrue(file.append(nextHeader))
        XCTAssertEqual(try contents(of: resultsPath), try earlier + Data("\n".utf8) + line(nextHeader))
        let recorded = try RecordedResults.read(contents(of: resultsPath), path: resultsPath)
        XCTAssertEqual(recorded.headers, [header, nextHeader])
        XCTAssertEqual(recorded.unreadableLines, [2])
        XCTAssertFalse(recorded.endsWithCutOffLine)
    }

    func test_openForResume_endsACutOffLastLine_beforeTheFirstLinesWrittenTogether() throws {
        let earlier = try line(header) + line(mutant) + line(MutantResult.make(line: 80)).prefix(10)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))
        let retired = ResultsRetired(session: 2, keys: [mutant.key])

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        XCTAssertTrue(file.append(contentsOf: [nextHeader, retired]))

        XCTAssertEqual(try contents(of: resultsPath), try earlier + Data("\n".utf8) + line(nextHeader) + line(retired))
        let recorded = try RecordedResults.read(contents(of: resultsPath), path: resultsPath)
        XCTAssertEqual(recorded.headers, [header, nextHeader])
        XCTAssertEqual(recorded.latest, [:], "the retired line is read")
        XCTAssertEqual(recorded.unreadableLines, [3])
    }

    // `--resume` may name a file that isn't a results file, and a resume may be refused, or its baseline fail. Until
    // the session writes a line, the file is left as it was, whatever it holds.
    func test_openForResume_writesNothing_untilALineIsAppended() throws {
        let report = Data(#"{"a":1}"#.utf8)
        try report.write(to: URL(fileURLWithPath: resultsPath))

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        file.close()

        XCTAssertEqual(try contents(of: resultsPath), report)
    }

    func test_openForResume_leavesAFileEndingInALineBreakAsItIs() throws {
        let earlier = try line(header) + line(mutant) + line(end)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))

        _ = try ResultsFile.Opener().openForResume(at: resultsPath)

        XCTAssertEqual(try contents(of: resultsPath), earlier)
    }

    // A last line written in full but without its line break reads fine, and must still read once more lines follow.
    func test_openForResume_keepsAWholeLastLineWithoutItsBreakReadable() throws {
        try (line(header) + line(mutant).dropLast()).write(to: URL(fileURLWithPath: resultsPath))

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        XCTAssertTrue(file.append(nextHeader))

        XCTAssertEqual(try contents(of: resultsPath), try line(header) + line(mutant) + line(nextHeader))
        let recorded = try RecordedResults.read(contents(of: resultsPath), path: resultsPath)
        XCTAssertEqual(recorded.headers, [header, nextHeader])
        XCTAssertEqual(recorded.latest, [mutant.key: mutant])
        XCTAssertEqual(recorded.unreadableLines, [])
    }

    func test_openForResume_appends_neverOverwrites() throws {
        let earlier = try line(header) + line(mutant) + line(end)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))
        let nextMutant = MutantResult.make(session: 2, line: 80)

        let file = try ResultsFile.Opener().openForResume(at: resultsPath)
        XCTAssertTrue(file.append(nextHeader))
        XCTAssertTrue(file.append(nextMutant))

        XCTAssertEqual(file.path, resultsPath)
        XCTAssertEqual(try contents(of: resultsPath), try earlier + line(nextHeader) + line(nextMutant))
        XCTAssertNil(file.writeError)
    }

    // The run that holds the lock may be part way through writing a line: a refused resume must write nothing, not
    // even the line break that would end it.
    func test_openForResume_isRefusedWhileAnotherHoldsTheLock() throws {
        let earlier = try line(header) + line(mutant).prefix(10)
        try earlier.write(to: URL(fileURLWithPath: resultsPath))
        let running = try makeFile()
        let holder = try XCTUnwrap(LockHolder.current())

        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .inUse(path: resultsPath, holder: .running(holder)))
        }
        XCTAssertEqual(try contents(of: resultsPath), earlier)

        running.close()
        XCTAssertNoThrow(try ResultsFile.Opener().openForResume(at: resultsPath))
    }

    func test_openForResume_ofAMissingFile_saysWhy() {
        XCTAssertThrowsError(try ResultsFile.Opener().openForResume(at: resultsPath)) { error in
            XCTAssertEqual(error as? ResultsFileError, .cannotOpen(path: resultsPath, errno: ENOENT))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: resultsPath), "it never makes a file")
    }
}
