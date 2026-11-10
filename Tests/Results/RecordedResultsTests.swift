@testable import muterCore
import XCTest

final class RecordedResultsTests: XCTestCase {
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

    // A property rerun is of the result it follows: a later line of the key, or its retirement, sets it aside.
    func test_aPropertyRerun_isKeptForTheResultItFollows_andOutcomesCarryIt() throws {
        let rerun = propertyRerun(of: sum, outcome: .failed)
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .failed)

        let kept = try read(file(header, sum, rerun, product, end))
        let replaced = try read(file(header, sum, rerun, product, end, resumed, retested))
        let retirement = ResultsRetired(session: 2, keys: [sum.key])
        let retired = try read(file(header, sum, rerun, product, end, resumed, retirement))
        let orphan = try read(file(header, rerun, end))

        XCTAssertEqual(kept.propertyReruns, [sum.key: rerun])
        XCTAssertEqual(kept.unreadableLines, [])
        XCTAssertEqual(replaced.propertyReruns, [:])
        XCTAssertEqual(retired.propertyReruns, [:])
        XCTAssertEqual(orphan.propertyReruns, [:], "of no result")
        XCTAssertEqual(orphan.unreadableLines, [], "read, but kept for no result")
        let outcome = kept.mutationTestOutcome()
        XCTAssertEqual(outcome.mutations.map(\.propertyRerun?.outcome).compactMap(\.self), [.failed])
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
        let newer = try file(ResultsHeader.make(formatVersion: 5), sum)
        let newerAndUnlikeThisOne = Data(#"{"formatVersion":5,"kind":"header"}"#.utf8)
        let newerSecondSession = try file(header, sum, end, ResultsHeader.make(formatVersion: 6, session: 2))

        for (data, version) in [(newer, 5), (newerAndUnlikeThisOne, 5), (newerSecondSession, 6)] {
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

    // A format-4 session's kills by a test their lines name keep no log, and their lines, which have no `log`, are read
    // with the rest.
    func test_format4_isRead_withItsLinesWithoutALog() throws {
        let killed = MutantResult.make(
            path: "Sources/Sum.swift",
            finishedAt: ResultsHeader.fixedStart + 31.25,
            killedBy: [.init(name: "sum()", location: "SumTests.swift:3:5")],
            keptLog: false
        )
        let survived = MutantResult.make(
            path: "Sources/Product.swift", outcome: .passed, finishedAt: ResultsHeader.fixedStart + 62.5
        )

        let recorded = try read(
            file(ResultsHeader.make(formatVersion: ResultsCoding.omittedLogsFormatVersion), killed, survived, end)
        )

        XCTAssertEqual(recorded.headers.map(\.formatVersion), [4])
        XCTAssertEqual(recorded.latest, [killed.key: killed, survived.key: survived])
        XCTAssertNil(recorded.latest[killed.key]?.log)
        XCTAssertNotNil(recorded.latest[survived.key]?.log)
        XCTAssertEqual(recorded.unreadableLines, [])
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
        let secondHeader = ResultsHeader.make(session: 2, startedAt: ResultsHeader.fixedStart + 3_600)
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .timeout)

        let sameSession = try read(file(header, sum, survived))
        let laterSession = try read(file(header, sum, end, secondHeader, retested))

        XCTAssertEqual(sameSession.latest, [sum.key: survived])
        XCTAssertEqual(laterSession.latest, [sum.key: retested])
        XCTAssertEqual(laterSession.headers, [header, secondHeader])
    }

    func test_testDuration_usesEndLines_andEstimatesSessionsWithout() throws {
        let secondStart = ResultsHeader.fixedStart + 3_600
        let interrupted = ResultsHeader.make(session: 2, startedAt: secondStart)
        let killedBeforeAnyMutant = ResultsHeader.make(session: 3, startedAt: secondStart + 3_600)

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
