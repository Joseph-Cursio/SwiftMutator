@testable import muterCore
import TestingExtensions
import XCTest

final class ResultsRecordTests: XCTestCase {
    func test_aHeaderCountsTheDroppedMutants_andLeavesOutNone() throws {
        let state = MutationTestState()
        let header = {
            ResultsHeader(
                session: 1,
                startedAt: Date(timeIntervalSince1970: 0),
                state: state,
                logDirectory: "/logs",
                configuration: .init(executable: "swift", arguments: []),
                baselineSeconds: 1,
                workers: 1,
                mutantsDiscovered: 1,
                mutantsToTest: 1,
                provenance: .fixture
            )
        }
        XCTAssertNil(header().mutantsDropped)
        XCTAssertFalse(String(lossyUTF8: try JSONEncoder().encode(header())).contains("mutantsDropped"))

        state.droppedMutants = [
            DroppedMutant(
                path: "main.swift",
                mutationOperatorId: .ror,
                position: .null,
                snapshot: .null,
                lines: nil,
                reason: .noPlaceForASwitch
            ),
        ]

        XCTAssertEqual(header().mutantsDropped, 1)
        XCTAssertTrue(
            String(lossyUTF8: try JSONEncoder().encode(header())).contains(#""mutantsDropped":1"#)
        )
    }

    // Absent when the session doesn't know them, and with `--skip-coverage`, which has none; empty when it looked and
    // found none, so that results without them make no baseline file; otherwise each with its key and snapshot, read
    // back as written.
    func test_aHeaderRecordsTheMutantsOfCodeNoTestRan_andReadsThemBack() throws {
        let state = MutationTestState()
        let header = {
            ResultsHeader(
                session: 1,
                startedAt: self.startedAt,
                state: state,
                logDirectory: "/logs",
                configuration: .init(executable: "swift", arguments: []),
                baselineSeconds: 1,
                workers: 1,
                mutantsDiscovered: 1,
                mutantsToTest: 1,
                provenance: .fixture
            )
        }
        XCTAssertNil(header().mutantsNotCovered)
        XCTAssertFalse(try line(header()).contains("mutantsNotCovered"))

        let uncovered = UncoveredMutant(
            key: MutantKey(path: "Sources/New.swift", mutationOperatorId: .ror, line: 4, column: 9, occurrence: 1),
            snapshot: .make(before: "<", after: ">", description: "changed < to >")
        )
        state.apply([.mutantsNotCovered([uncovered])])

        XCTAssertEqual(header().mutantsNotCovered, [uncovered])
        let written = try line(header())
        XCTAssertTrue(written.contains(#""mutantsNotCovered":[{"column":9,"line":4,"#), written)
        XCTAssertEqual(try decode(ResultsHeader.self, from: written), header())
        XCTAssertEqual(uncovered.key.description, "Sources/New.swift:4:9 RelationalOperatorReplacement (#2)")

        state.apply([.mutantsNotCovered([])])
        XCTAssertTrue(try line(header()).contains(#""mutantsNotCovered":[]"#))
        state.runOptions = .make(skipCoverage: true)
        XCTAssertNil(header().mutantsNotCovered)
        XCTAssertEqual(header().knownMutantsNotCovered, [])
    }

    func test_aMutantRecordRoundTrips() throws {
        let record = makeMutantRecord(fileSHA256: "404db321")

        XCTAssertEqual(try decode(MutantResult.self, from: line(record)), record)
    }

    func test_aHeaderAndAnEndRecordRoundTrip() throws {
        let header = makeHeader()
        let headerWithoutAProject = makeHeader(project: nil)
        let resumedHeader = makeHeader(mutantsReused: 1_103, waived: ["README.md"], forced: ["toolchain.environment"])
        let end = makeEnd()

        XCTAssertEqual(try decode(ResultsHeader.self, from: line(header)), header)
        XCTAssertEqual(try decode(ResultsHeader.self, from: line(headerWithoutAProject)), headerWithoutAProject)
        XCTAssertEqual(try decode(ResultsHeader.self, from: line(resumedHeader)), resumedHeader)
        XCTAssertEqual(try decode(ResultsEnd.self, from: line(end)), end)
    }

    func test_eachRecordSaysItsKind() throws {
        let retired = ResultsRetired(session: 2, keys: [MutantResult.make().key])

        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(makeHeader())).kind, "header")
        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(makeMutantRecord())).kind, "mutant")
        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(retired)).kind, "retired")
        XCTAssertEqual(try decode(ResultsCoding.Kind.self, from: line(makeEnd())).kind, "end")
    }

    func test_aRecordIsOneLine_evenWithLineBreaksInItsSnapshot() throws {
        let record = makeMutantRecord(
            snapshot: .make(
                before: "if a {\n    b()\r\n}",
                after: "if a {\n}\u{2028}",
                description: "removed\tb()\u{1B}[0m"
            ),
            firstFailedTestLine: "✘ Test sum() recorded an issue at SumTests.swift:12:5: \"a\nb\""
        )

        let data = try ResultsCoding.encoder.encode(record)

        XCTAssertFalse(data.contains(UInt8(ascii: "\n")))
        XCTAssertFalse(data.contains(UInt8(ascii: "\r")))
        XCTAssertFalse(data.contains(0x1B))
        XCTAssertEqual(try ResultsCoding.decoder.decode(MutantResult.self, from: data), record)
    }
}
