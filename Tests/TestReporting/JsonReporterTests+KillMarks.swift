@testable import muterCore
import TestingExtensions
import XCTest

extension JsonReporterTests {
    // Where a reused result was tested; a result this run tested has no such key, and reads back without one.
    func test_aReusedResult_saysWhereItWasTested_andReadsBack() throws {
        let reused = ReusedFrom(resultsFile: "/logs/results.jsonl", session: 2, despiteChanges: true)
        let outcome = MutationTestOutcome.make(
            mutations: [.make(testSuiteOutcome: .passed, reusedFrom: reused), .make()]
        )
        let json = JsonReporter().report(from: outcome)

        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fileReports = try XCTUnwrap(report["fileReports"] as? [[String: Any]])
        let operators = try fileReports.flatMap { try XCTUnwrap($0["appliedOperators"] as? [[String: Any]]) }
        let marks = operators.compactMap { $0["reusedFrom"] as? [String: Any] }
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks.first?["resultsFile"] as? String, "/logs/results.jsonl")
        XCTAssertEqual(marks.first?["session"] as? Int, 2)
        XCTAssertEqual(marks.first?["despiteChanges"] as? Bool, true)

        let decoded = try JSONDecoder().decode(MuterTestReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.fileReports.flatMap(\.appliedOperators).compactMap(\.reusedFrom), [reused])
    }

    func test_aSuspectOnlyKill_isMarked_andTheSummaryGivesTheScoreWithoutThem() throws {
        let json = JsonReporter().report(from: .withSuspectTests)

        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fileReports = try XCTUnwrap(report["fileReports"] as? [[String: Any]])
        let operators = try fileReports.flatMap { try XCTUnwrap($0["appliedOperators"] as? [[String: Any]]) }
        let marked = operators.filter { $0["killedOnlyBySuspectTests"] != nil }
        XCTAssertEqual(marked.count, 6)
        XCTAssertTrue(marked.allSatisfy { $0["killedOnlyBySuspectTests"] as? Bool == true })
        XCTAssertTrue(marked.allSatisfy { $0["testSuiteOutcome"] as? String == "failed" })
        XCTAssertEqual(report["globalMutationScore"] as? Int, 92)
        XCTAssertEqual(report["numberOfKilledMutants"] as? Int, 13)

        let summary = try XCTUnwrap(report["killingTestSummary"] as? [String: Any])
        XCTAssertEqual(summary["suspectOnlyKills"] as? Int, 6)
        XCTAssertEqual(summary["suspectOnlyKillsWithIncompleteLists"] as? Int, 1)
        XCTAssertEqual(summary["mutationScoreWithoutSuspectOnlyKills"] as? Int, 50)

        // And it reads back as it was.
        let original = MuterTestReport(from: .withSuspectTests)
        let decoded = try JSONDecoder().decode(MuterTestReport.self, from: Data(json.utf8))
        XCTAssertEqual(
            decoded.fileReports.flatMap(\.appliedOperators),
            original.fileReports.flatMap(\.appliedOperators)
        )
        XCTAssertEqual(decoded.killingTestSummary, original.killingTestSummary)

        // Without suspects, the score is left out.
        let withoutSuspects = try topLevelKeys(of: .withKillingTests)["killingTestSummary"] as? [String: Any]
        XCTAssertNil(withoutSuspects?["mutationScoreWithoutSuspectOnlyKills"])
        XCTAssertEqual(withoutSuspects?["suspectOnlyKills"] as? Int, 0)
    }
}
