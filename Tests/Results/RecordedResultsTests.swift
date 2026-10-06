@testable import muterCore
import XCTest

final class RecordedResultsTests: XCTestCase {
    private let path = "/logs/results.jsonl"
    private let header = ResultsHeader.make()
    private let sum = MutantResult.make(path: "Sources/Sum.swift", finishedAt: ResultsHeader.fixedStart + 31.25)
    private let product = MutantResult.make(path: "Sources/Product.swift", finishedAt: ResultsHeader.fixedStart + 62.5)
    private let end = ResultsEnd.make(testDurationSeconds: 100.5, recorded: 2)
    private let resumed = ResultsHeader.make(
        formatVersion: ResultsCoding.resumedFormatVersion,
        session: 2,
        startedAt: ResultsHeader.fixedStart + 3600
    )

    func test_readsHeaderMutantsAndEnd() throws {
        let recorded = try read(file(header, sum, product, end))

        XCTAssertEqual(
            recorded.sessions,
            [RecordedResults.Session(header: header, end: end, lastFinishedAt: product.finishedAt)]
        )
        XCTAssertEqual(recorded.headers, [header])
        XCTAssertEqual(recorded.latest, [sum.key: sum, product.key: product])
        XCTAssertEqual(recorded.unreadableLines, [])
        XCTAssertFalse(recorded.endsWithCutOffLine)
        XCTAssertEqual(recorded.testDuration, 100.5)
    }

    func test_aCutOffLastLine_isSkippedAndSaidToBeCutOff() throws {
        let recorded = try read(file(header, sum) + line(product).prefix(40))

        XCTAssertEqual(recorded.latest, [sum.key: sum])
        XCTAssertEqual(recorded.unreadableLines, [3])
        XCTAssertTrue(recorded.endsWithCutOffLine)
    }

    func test_aLastLineWithoutItsLineBreak_isReadIfItIsWhole() throws {
        let recorded = try read(file(header, sum) + line(product).dropLast())

        XCTAssertEqual(recorded.latest, [sum.key: sum, product.key: product])
        XCTAssertEqual(recorded.unreadableLines, [])
        XCTAssertFalse(recorded.endsWithCutOffLine)
    }

    func test_aGarbledMiddleLine_isSkipped_andItsNumberKept() throws {
        let recorded = try read(
            file(header, sum)
                + Data("{\"kind\":\"mutant\",\"pa\n".utf8)
                + Data("{\"kind\":\"mutant\",\"session\":1}\n".utf8)
                + Data("[1, 2]\n".utf8)
                + file(product, end)
        )

        XCTAssertEqual(recorded.latest, [sum.key: sum, product.key: product])
        XCTAssertEqual(recorded.unreadableLines, [3, 4, 5])
        XCTAssertFalse(recorded.endsWithCutOffLine)
        XCTAssertEqual(recorded.sessions.first?.end, end)
    }

    func test_NULPadding_isSkipped() throws {
        let padding = Data(repeating: 0, count: 300)

        let atTheEnd = try read(file(header, sum) + padding)
        let thenResumed = try read(file(header, sum) + padding + Data("\n".utf8) + file(product))

        XCTAssertEqual(atTheEnd.latest, [sum.key: sum])
        XCTAssertEqual(atTheEnd.unreadableLines, [3])
        XCTAssertTrue(atTheEnd.endsWithCutOffLine)
        XCTAssertEqual(thenResumed.latest, [sum.key: sum, product.key: product])
        XCTAssertEqual(thenResumed.unreadableLines, [3])
        XCTAssertFalse(thenResumed.endsWithCutOffLine)
    }

    func test_emptyLinesAreSkipped_andNotUnreadable() throws {
        let recorded = try read(Data("\n".utf8) + file(header) + Data("\n\n".utf8) + file(sum))

        XCTAssertEqual(recorded.latest, [sum.key: sum])
        XCTAssertEqual(recorded.unreadableLines, [])
    }

    func test_unknownKindsAreIgnored() throws {
        let recorded = try read(
            file(header)
                + Data(#"{"keys":[{"path":"Sources/Sum.swift"}],"kind":"annotation","session":1}"#.utf8)
                + Data("\n".utf8)
                + file(sum)
        )

        XCTAssertEqual(recorded.latest, [sum.key: sum])
        XCTAssertEqual(recorded.unreadableLines, [])
    }

    func test_aRetiredKeyIsDropped() throws {
        let neverRecorded = MutantKey(
            path: "Sources/Gone.swift", mutationOperatorId: .ror, line: 4, column: 9, occurrence: 0
        )

        let recorded = try read(
            file(header, sum, product, end, resumed, ResultsRetired(session: 2, keys: [sum.key, neverRecorded]))
        )

        XCTAssertEqual(recorded.latest, [product.key: product])
        XCTAssertEqual(recorded.unreadableLines, [])
        XCTAssertEqual(recorded.headers, [header, resumed])
    }

    // A resumed session retires the results it tests again, then records them as it tests them.
    func test_aKeyRecordedAgainAfterItsRetirement_isKept() throws {
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .passed)

        let recorded = try read(
            file(header, sum, product, end, resumed, ResultsRetired(session: 2, keys: [sum.key, product.key]), retested)
        )

        XCTAssertEqual(recorded.latest, [sum.key: retested])
        XCTAssertEqual(recorded.unreadableLines, [])
    }

    func test_aRetiredLineOfNoEarlierSession_isUnreadable() throws {
        let beforeAnyHeader = try read(file(ResultsRetired(session: 1, keys: [sum.key]), header, sum))
        let ofALaterSession = try read(file(header, sum, ResultsRetired(session: 2, keys: [sum.key])))

        XCTAssertEqual(beforeAnyHeader.latest, [sum.key: sum])
        XCTAssertEqual(beforeAnyHeader.unreadableLines, [1])
        XCTAssertEqual(ofALaterSession.latest, [sum.key: sum])
        XCTAssertEqual(ofALaterSession.unreadableLines, [3])
    }

    func test_aFileWithoutAHeader_isRefused() throws {
        let headerless = try file(sum, end)
        let garbledHeader = try line(header).dropFirst(5) + file(sum)

        for data in [headerless, garbledHeader] {
            XCTAssertThrowsError(try read(data)) { error in
                XCTAssertEqual(error as? ResultsFileError, .notAResultsFile(path: path))
            }
        }
    }

    func test_anEmptyFile_isRefused() {
        for data in [Data(), Data("\n\n".utf8)] {
            XCTAssertThrowsError(try read(data)) { error in
                XCTAssertEqual(error as? ResultsFileError, .notAResultsFile(path: path))
            }
        }
    }

    func test_aNewerFormat_isRefused() throws {
        let newer = try file(ResultsHeader.make(formatVersion: 3), sum)
        let newerAndUnlikeThisOne = Data(#"{"formatVersion":3,"kind":"header"}"#.utf8)
        let newerSecondSession = try file(header, sum, end, ResultsHeader.make(formatVersion: 4, session: 2))

        for (data, version) in [(newer, 3), (newerAndUnlikeThisOne, 3), (newerSecondSession, 4)] {
            XCTAssertThrowsError(try read(data)) { error in
                XCTAssertEqual(error as? ResultsFileError, .newerFormat(path: path, version: version))
            }
        }
    }

    // A resumed session's header is in format 2, as its file holds retired lines; a first session's stays in 1.
    func test_format2_isRead() throws {
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .passed)
        let resumedEnd = ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 1)

        let recorded = try read(
            file(header, sum, product, end, resumed, ResultsRetired(session: 2, keys: [sum.key]), retested, resumedEnd)
        )

        XCTAssertEqual(recorded.headers.map(\.formatVersion), [1, 2])
        XCTAssertEqual(recorded.sessions.map(\.end), [end, resumedEnd])
        XCTAssertEqual(recorded.latest, [sum.key: retested, product.key: product])
        XCTAssertEqual(recorded.unreadableLines, [])
        XCTAssertEqual(recorded.testDuration, 120.75)
    }

    func test_aMutantLineBeforeAnyHeader_isUnreadable() throws {
        let laterSession = MutantResult.make(session: 2, path: "Sources/Quotient.swift")

        let recorded = try read(file(sum, header, product, laterSession, ResultsEnd.make(session: 2)))

        XCTAssertEqual(recorded.latest, [product.key: product])
        XCTAssertEqual(recorded.unreadableLines, [1, 4, 5])
        XCTAssertEqual(recorded.sessions.map(\.end), [nil])
    }

    func test_theLastRecordOfAKeyWins() throws {
        let survived = MutantResult.make(path: sum.path, outcome: .passed)
        let secondHeader = ResultsHeader.make(session: 2, startedAt: ResultsHeader.fixedStart + 3600)
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .timeout)

        let sameSession = try read(file(header, sum, survived))
        let laterSession = try read(file(header, sum, end, secondHeader, retested))

        XCTAssertEqual(sameSession.latest, [sum.key: survived])
        XCTAssertEqual(laterSession.latest, [sum.key: retested])
        XCTAssertEqual(laterSession.headers, [header, secondHeader])
    }

    func test_testDuration_usesEndLines_andEstimatesSessionsWithout() throws {
        let secondStart = ResultsHeader.fixedStart + 3600
        let interrupted = ResultsHeader.make(session: 2, startedAt: secondStart)
        let killedBeforeAnyMutant = ResultsHeader.make(session: 3, startedAt: secondStart + 3600)

        let recorded = try read(
            file(
                header,
                sum,
                ResultsEnd.make(testDurationSeconds: 100.5),
                interrupted,
                MutantResult.make(session: 2, path: "Sources/Product.swift", finishedAt: secondStart + 30.25),
                MutantResult.make(session: 2, path: "Sources/Quotient.swift", finishedAt: secondStart + 10),
                killedBeforeAnyMutant
            )
        )

        XCTAssertEqual(recorded.sessions.map(\.lastFinishedAt), [sum.finishedAt, secondStart + 30.25, nil])
        XCTAssertEqual(recorded.sessions.map(\.testDuration), [100.5, 30.25, 0])
        XCTAssertEqual(recorded.testDuration, 130.75)
    }
}

private extension RecordedResultsTests {
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
