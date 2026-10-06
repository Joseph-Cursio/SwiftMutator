@testable import muterCore
import TestingExtensions
import XCTest

final class JsonReporterTests: ReporterTestCase {
    func test_report() throws {
        let json = JsonReporter()
            .report(
                from: .make(mutations: outcomes)
            )

        let data = try XCTUnwrap(json.data(using: .utf8))
        let actualReport = try XCTUnwrap(JSONDecoder().decode(MuterTestReport.self, from: data))

        // The reports differ and can't be equated easily as we do not persist the path of a file report.
        // Basically, when we deserialize it, it's missing a field (`path`).
        XCTAssertEqual(actualReport.totalAppliedMutationOperators, 1)
        XCTAssertEqual(actualReport.fileReports.first?.fileName, "file3.swift")
        XCTAssertEqual(
            actualReport.fileReports.first?.appliedOperators.map(\.mutationSnapshot),
            [.init(before: "!=", after: "==", description: "from != to ==")]
        )
    }

    func test_aKilledMutantListsItsKillingTests_aSurvivorKeepsExactlyItsKeys() throws {
        let killingTests = MutationTestOutcome.KillingTests(
            tests: [
                .init(name: "sum()", location: "SumTests.swift:3:5"),
                .init(name: "-[Tests.SumTests testTotal]", location: nil),
            ],
            count: 3,
            isComplete: false
        )
        let json = JsonReporter().report(from: .make(mutations: [
            .make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/tmp/project/Sum.swift", position: 3),
                killingTests: killingTests
            ),
            .make(testSuiteOutcome: .passed, point: .make(filePath: "/tmp/project/Sum.swift", position: 7)),
        ]))

        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let fileReports = try XCTUnwrap(report["fileReports"] as? [[String: Any]])
        let operators = try XCTUnwrap(fileReports.first?["appliedOperators"] as? [[String: Any]])
        XCTAssertEqual(operators.count, 2)
        let kill = try XCTUnwrap(operators.first { $0["testSuiteOutcome"] as? String == "failed" })
        let survivor = try XCTUnwrap(operators.first { $0["testSuiteOutcome"] as? String == "passed" })

        XCTAssertEqual(kill["killingTests"] as? NSDictionary, [
            "tests": [
                ["name": "sum()", "location": "SumTests.swift:3:5"],
                ["name": "-[Tests.SumTests testTotal]"],
            ],
            "count": 3,
            "isComplete": false,
        ] as NSDictionary)
        let tests = try XCTUnwrap((kill["killingTests"] as? [String: Any])?["tests"] as? [[String: Any]])
        XCTAssertEqual(tests.last?.keys.sorted(), ["name"], "an XCTest name has no location")
        XCTAssertEqual(survivor.keys.sorted(), ["mutationPoint", "mutationSnapshot", "testSuiteOutcome"])
    }
}
