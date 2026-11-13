@testable import muterCore
import XCTest

extension ResultsRecordTests {
    func test_keysAreSorted_andSlashesAreNotEscaped() throws {
        XCTAssertEqual(
            try line(makeMutantRecord()),
            [
                #"{"column":22,"durationSeconds":31.207,"endedBy":"exited","exitStatus":1,"failedTestCount":3,"#,
                #""finishedAt":"2026-10-04T13:18:02.125Z","#,
                #""firstFailedTestLine":"✘ Test detectsExecutableTargets() recorded an issue at "#,
                #"ExecutableTargetDetectorTests.swift:41:9: Expectation failed","#,
                #""killedBy":[{"location":"ExecutableTargetDetectorTests.swift:41:9","#,
                #""name":"detectsExecutableTargets()"}],"kind":"mutant","line":73,"#,
                #""log":"RelationalOperatorReplacement @ ExecutableTargetDetector.swift-73-22.log","#,
                #""mutationOperatorId":"RelationalOperatorReplacement","occurrence":0,"outcome":"failed","#,
                #""path":"Packages/Core/Sources/Core/ExecutableTargetDetector.swift","session":1,"#,
                #""snapshot":{"after":"<","before":">","description":"changed > to <"},"#,
                #""switchID":"ExecutableTargetDetector_1202e16ea88d5e02_RelationalOperatorReplacement_73_22_3361","#,
                #""utf8Offset":3361,"worker":2}"#,
            ].joined()
        )
        XCTAssertEqual(
            try line(makeEnd()),
            [
                #"{"detail":"tooManyBuildErrors","endedAt":"2026-10-04T14:02:11.125Z","kind":"end","#,
                #""reason":"aborted","recorded":1103,"session":1,"testDurationSeconds":2766.493}"#,
            ].joined()
        )

        let header = try line(makeHeader())
        XCTAssertTrue(header.contains(#""projectPath":"/Users/me/Project""#), header)
        XCTAssertFalse(header.contains(#"\/"#), header)
    }

    func test_datesKeepMilliseconds() throws {
        // No binary fraction is .004 exactly, so a date read back from it is a hair under it.
        let end = makeEnd(endedAt: Date(timeIntervalSince1970: 1_791_122_531.004))

        let written = try line(end)
        let readBack = try decode(ResultsEnd.self, from: written)

        XCTAssertTrue(written.contains(#""endedAt":"2026-10-04T14:02:11.004Z""#), written)
        XCTAssertEqual(readBack.endedAt.timeIntervalSince1970, 1_791_122_531.004, accuracy: 0.00001)
        XCTAssertEqual(try line(readBack), written, "a date read back is written as it was")
    }

    func test_datesAreRoundedToTheNearestMillisecond() throws {
        XCTAssertTrue(
            try line(makeEnd(endedAt: Date(timeIntervalSince1970: 1_791_122_531.0006)))
                .contains(#""endedAt":"2026-10-04T14:02:11.001Z""#)
        )
        XCTAssertTrue(
            try line(makeEnd(endedAt: Date(timeIntervalSince1970: 1_791_122_531.9996)))
                .contains(#""endedAt":"2026-10-04T14:02:12.000Z""#)
        )
    }

    func test_datesWithoutFractionalSeconds_areRead() throws {
        let written = try line(makeEnd()).replacingOccurrences(of: "14:02:11.125Z", with: "14:02:11Z")

        XCTAssertEqual(
            try decode(ResultsEnd.self, from: written).endedAt,
            Date(timeIntervalSince1970: 1_791_122_531)
        )
    }

    func test_nilFieldsAreLeftOut() throws {
        let record = try line(
            makeMutantRecord(
                outcome: .passed,
                exitStatus: nil,
                killedBy: nil,
                failedTestCount: nil,
                firstFailedTestLine: nil
            )
        )
        let header = try line(
            makeHeader(
                coverage: nil,
                baselineSeconds: nil,
                testRunSeconds: nil,
                timeoutSeconds: nil,
                project: nil,
                provenance: Provenance(
                    swiftMutator: .init(version: "1.0.0", executablePath: nil, executableSHA256: nil),
                    toolchain: .init(testCommandVersion: nil, testExecutableSHA256: nil, environment: [:]),
                    processIdentifier: 81_234,
                    host: "host",
                    arguments: []
                )
            )
        )
        let end = try line(makeEnd(reason: .finished, detail: nil))
        let location = try line(FailedTestLine.FailedTest(name: "-[SumTests testSum]", location: nil))

        for key in ["exitStatus", "killedBy", "failedTestCount", "firstFailedTestLine", "fileSHA256"] {
            XCTAssertFalse(record.contains("\"\(key)\""), "\(key) in \(record)")
        }
        for key in [
            "coverage", "baselineSeconds", "testRunSeconds", "timeoutSeconds", "executablePath", "executableSHA256",
            "testCommandVersion", "testExecutableSHA256", "mutationTestTimeout", "buildSystem", "project",
            "mutantsReused", "waived", "forced", "testBundlesRunDirectly", "configurationWorkedOut", "testPlan",
        ] {
            XCTAssertFalse(header.contains("\"\(key)\""), "\(key) in \(header)")
        }
        XCTAssertFalse(end.contains(#""detail""#), end)
        XCTAssertEqual(location, #"{"name":"-[SumTests testSum]"}"#)
        for written in [record, header, end] {
            XCTAssertFalse(written.contains("null"), written)
        }
    }

    func test_unknownKeysAreIgnored() throws {
        let record = makeMutantRecord()
        let header = makeHeader()
        let end = makeEnd()

        XCTAssertEqual(try decode(MutantResult.self, from: withKeyAddedLater(to: line(record))), record)
        XCTAssertEqual(try decode(ResultsHeader.self, from: withKeyAddedLater(to: line(header))), header)
        XCTAssertEqual(try decode(ResultsEnd.self, from: withKeyAddedLater(to: line(end))), end)
        XCTAssertEqual(
            try decode(
                MutantResult.self,
                from: line(record).replacingOccurrences(of: #""snapshot":{"#, with: #""snapshot":{"addedLater":1,"#)
            ),
            record
        )
    }
}
