@testable import muterCore
import XCTest

final class OperatorExplanationTests: ReporterTestCase {
    private var outcome: MutationTestOutcome {
        .make(mutations: [
            .make(
                testSuiteOutcome: .passed,
                point: .make(mutationOperatorId: .swapTernary, filePath: "/tmp/project/Sum.swift", position: 3)
            ),
            .make(
                testSuiteOutcome: .failed,
                point: .make(mutationOperatorId: .swapTernary, filePath: "/tmp/project/Sum.swift", position: 7)
            ),
            .make(
                testSuiteOutcome: .failed,
                point: .make(mutationOperatorId: .ror, filePath: "/tmp/project/Sum.swift", position: 9)
            ),
        ])
    }

    func test_theJSONReport_explainsOnlyTheOperatorsUsed() throws {
        let json = JsonReporter().report(from: outcome)

        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(report["operatorExplanations"] as? [String: String], [
            "SwapTernary": MutationOperator.Id.swapTernary.explanation,
            "RelationalOperatorReplacement": MutationOperator.Id.ror.explanation,
        ])
    }

    func test_reportsWithoutMutants_explainNothing() throws {
        let none = MutationTestOutcome.make(mutations: [])

        let report = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: none).utf8)) as? [String: Any]
        )
        XCTAssertNil(report["operatorExplanations"])
        XCTAssertFalse(PlainTextReporter().report(from: none).contains("What these operators do:"))
    }

    // A JSON report written before reports had them can still be read.
    func test_aJSONReportWithoutThem_isRead() throws {
        var report = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        report["operatorExplanations"] = nil

        let read = try JSONDecoder().decode(
            MuterTestReport.self,
            from: JSONSerialization.data(withJSONObject: report)
        )

        XCTAssertNil(read.operatorExplanations)
    }

    func test_thePlainReport_explainsEachOperatorOnce_afterTheTable_byName() throws {
        let text = PlainTextReporter().report(from: outcome)

        let legend = """
        What these operators do:
        RelationalOperatorReplacement: \(MutationOperator.Id.ror.explanation)
        SwapTernary: \(MutationOperator.Id.swapTernary.explanation)
        """
        XCTAssertTrue(text.contains(legend), text)
        XCTAssertEqual(text.components(separatedBy: MutationOperator.Id.swapTernary.explanation).count, 2)
        let table = try XCTUnwrap(text.range(of: "Applied Mutation Operator "))
        let start = try XCTUnwrap(text.range(of: "What these operators do:"))
        XCTAssertLessThan(table.lowerBound, start.lowerBound)
    }

    // A survivor's row and every mutant's row each give it, where the name is.
    func test_theHTMLReport_explainsTheOperator_onItsNamesCell() {
        let html = HTMLReporter().report(from: outcome)

        XCTAssertEqual(html.components(separatedBy: "title=\"\(MutationOperator.Id.ror.explanation)\"").count, 2)
        XCTAssertEqual(
            html.components(separatedBy: "title=\"\(MutationOperator.Id.swapTernary.explanation)\"").count,
            4,
            "the survivor's row, and its row and the kill's among all the mutants"
        )
    }

    // The HTML report puts them in an attribute, as they are.
    func test_everyExplanation_isOneLine_ofWordsAlone() {
        for mutationOperator in MutationOperator.Id.allCases {
            let explanation = mutationOperator.explanation
            XCTAssertFalse(explanation.isEmpty, mutationOperator.rawValue)
            XCTAssertFalse(explanation.contains { "<>&\"\n".contains($0) }, explanation)
        }
    }
}
