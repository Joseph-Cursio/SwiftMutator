@testable import muterCore
import XCTest

final class MuterTestReportTests: MuterTestCase {
    func test_calculatingNonEmptyTestOutcomes() {
        let outcome =
            MutationTestOutcome.make(
                mutations:
                exampleMutationTestResults + [
                    MutationTestOutcome.Mutation.make(
                        testSuiteOutcome: .failed,
                        point: MutationPoint(
                            mutationOperatorId: .ror,
                            filePath: "/tmp/a module.swift",
                            position: .firstPosition
                        ),
                        snapshot: .make(
                            before: "==",
                            after: "!=",
                            description: "changed from == to !="
                        )
                    ),
                ]
            )

        let report = MuterTestReport(from: outcome)

        XCTAssertEqual(report.globalMutationScore, 60)
        XCTAssertEqual(report.totalAppliedMutationOperators, 10)
        XCTAssertEqual(report.fileReports.count, 5)
        XCTAssertEqual(report.fileReports, [
            FileReportProvider.expectedFileReport1,
            FileReportProvider.expectedFileReport2,
            FileReportProvider.expectedFileReport3,
            FileReportProvider.expectedFileReport4,
            FileReportProvider.expectedFileReport5,
        ])
    }

    func test_calculatingEmptyTestOutcomes() {
        let report = MuterTestReport(from: .make())

        XCTAssertEqual(report.globalMutationScore, -1)
        XCTAssertEqual(report.totalAppliedMutationOperators, 0)
        XCTAssertTrue(report.fileReports.isEmpty)
    }

    func test_mutationScore() {
        let expectedMutationScores = [
            "/tmp/file1.swift": 66,
            "/tmp/file2.swift": 100,
            "/tmp/file3.swift": 33,
            "/tmp/file 4.swift": 0,
        ]

        let actualMutationScores = mutationScoresOfFiles(from: exampleMutationTestResults)

        XCTAssertEqual(actualMutationScores, expectedMutationScores)
    }

    func test_aReportWithKillingTests_roundTrips() throws {
        let report = MuterTestReport(from: .make(mutations: [
            .make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/tmp/Sum.swift", position: 3),
                killingTests: .init(
                    tests: [
                        .init(name: "sum()", location: "SumTests.swift:3:5"),
                        .init(name: "-[Tests.SumTests testTotal]", location: nil),
                    ],
                    count: 2,
                    isComplete: true
                )
            ),
            .make(
                testSuiteOutcome: .timeout,
                point: .make(filePath: "/tmp/Sum.swift", position: 5),
                killingTests: .init(tests: [], count: 0, isComplete: false)
            ),
            .make(testSuiteOutcome: .passed, point: .make(filePath: "/tmp/Sum.swift", position: 7)),
        ]))

        let decoded = try JSONDecoder().decode(MuterTestReport.self, from: JSONEncoder().encode(report))

        XCTAssertEqual(decoded.fileReports.map(\.appliedOperators), report.fileReports.map(\.appliedOperators))
        XCTAssertEqual(
            report.fileReports.flatMap(\.appliedOperators).map(\.killingTests?.count),
            [2, 0, nil]
        )
    }

    /// A JSON report written before reports named killing tests.
    func test_aReportWithoutTheNewKeys_stillDecodes() throws {
        let json = """
        {
          "globalMutationScore" : 50,
          "totalAppliedMutationOperators" : 2,
          "numberOfKilledMutants" : 1,
          "timeElapsed" : "00:01:02.500",
          "fileReports" : [
            {
              "fileName" : "Sum.swift",
              "mutationScore" : 50,
              "appliedOperators" : [
                {
                  "mutationPoint" : {
                    "mutationOperatorId" : "RelationalOperatorReplacement",
                    "filePath" : "/tmp/Sum.swift",
                    "position" : { "utf8Offset" : 30, "line" : 3, "column" : 5 }
                  },
                  "mutationSnapshot" : { "before" : ">", "after" : "<", "description" : "changed > to <" },
                  "testSuiteOutcome" : "failed"
                },
                {
                  "mutationPoint" : {
                    "mutationOperatorId" : "RemoveSideEffects",
                    "filePath" : "/tmp/Sum.swift",
                    "position" : { "utf8Offset" : 70, "line" : 7, "column" : 9 }
                  },
                  "mutationSnapshot" : { "before" : "log()", "after" : "removed line", "description" : "removed line" },
                  "testSuiteOutcome" : "passed"
                }
              ]
            }
          ]
        }
        """

        let report = try JSONDecoder().decode(MuterTestReport.self, from: Data(json.utf8))

        let operators = report.fileReports.flatMap(\.appliedOperators)
        XCTAssertEqual(operators.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(operators.map(\.mutationPoint.position.line), [3, 7])
        XCTAssertEqual(operators.map(\.killingTests), [nil, nil])
        XCTAssertEqual(report.numberOfKilledMutants, 1)
    }
}

extension MuterTestReportTests {
    var exampleMutationTestResults: [MutationTestOutcome.Mutation] {
        [
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file1.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file1.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file1.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .removeSideEffects,
                    filePath: "/tmp/file2.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .removeSideEffects,
                    filePath: "/tmp/file2.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .failed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file3.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file3.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file3.swift",
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
            .make(
                testSuiteOutcome: .passed,
                point: MutationPoint(
                    mutationOperatorId: .ror,
                    filePath: "/tmp/file 4.swift", // this file name intentionally has a space in it
                    position: .firstPosition
                ),
                snapshot: MutationOperator.Snapshot(
                    before: "==",
                    after: "!=",
                    description: "changed from == to !="
                )
            ),
        ]
    }
}
