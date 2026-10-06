@testable import muterCore
import XCTest

final class TestReportTableGenerationTests: MuterTestCase {
    private let fileReports = [
        FileReportProvider.expectedFileReport3,
        FileReportProvider.expectedFileReport4,
        FileReportProvider.expectedFileReport5,
        FileReportProvider.expectedFileReport2,
    ]

    func test_operatorsTable() {
        let expectedCLITable = CLITable(padding: 3, columns: [
            CLITable.Column(title: "File", rows: [
                CLITable.Row(value: "file1.swift:0"),
                CLITable.Row(value: "file1.swift:0"),
                CLITable.Row(value: "file1.swift:0"),
                CLITable.Row(value: "file2.swift:0"),
                CLITable.Row(value: "file2.swift:0"),
                CLITable.Row(value: "file3.swift:0"),
                CLITable.Row(value: "file3.swift:0"),
                CLITable.Row(value: "file3.swift:0"),
                CLITable.Row(value: "file 4.swift:0"),
            ]),
            CLITable.Column(title: "Applied Mutation Operator", rows: [
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "RemoveSideEffects"),
                CLITable.Row(value: "RemoveSideEffects"),
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "RelationalOperatorReplacement"),
            ]),
            CLITable.Column(title: "Mutation Test Result", rows: [
                CLITable.Row(value: "mutant killed (test failure)"),
                CLITable.Row(value: "mutant killed (test failure)"),
                CLITable.Row(value: "mutant survived"),
                CLITable.Row(value: "mutant killed (test failure)"),
                CLITable.Row(value: "mutant killed (test failure)"),
                CLITable.Row(value: "mutant killed (test failure)"),
                CLITable.Row(value: "mutant survived"),
                CLITable.Row(value: "mutant survived"),
                CLITable.Row(value: "mutant survived"),
            ]),
        ])

        let generatedCLITable = generateAppliedMutationOperatorsCLITable(from: fileReports, coloringFunction: { $0 })

        XCTAssertEqual(generatedCLITable, expectedCLITable)
    }

    func test_operatorsTable_withKillingTests_addsAKilledByColumn() {
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let total = FailedTestLine.FailedTest(name: "total()", location: "SumTests.swift:9:5")
        let operators: [MuterTestReport.AppliedMutationOperator] = [
            .make(testSuiteOutcome: .failed, killingTests: .init(tests: [sum], count: 1, isComplete: true)),
            .make(testSuiteOutcome: .failed, killingTests: .init(tests: [sum, total], count: 3, isComplete: false)),
            .make(testSuiteOutcome: .runtimeError, killingTests: .noneNamed),
            .make(testSuiteOutcome: .passed),
            .make(testSuiteOutcome: .timeout, killingTests: .init(tests: [], count: 0, isComplete: false)),
            .make(testSuiteOutcome: .buildError),
            // A kill whose failed-test lines weren't reliable has none recorded.
            .make(testSuiteOutcome: .failed),
        ]

        let table = operatorsTable(operators)

        XCTAssertEqual(
            table.columns.map(\.title),
            ["File", "Applied Mutation Operator", "Mutation Test Result", "Killed By"]
        )
        XCTAssertEqual(
            table.columns.last?.rows.map(\.value),
            ["sum()", "sum() (+2)", "(none named)", "-", "-", "-", "-"]
        )
    }

    func test_operatorsTable_whenNoKilledMutantRecordedItsTests_hasNoKilledByColumn() {
        // A timeout's run records an empty list, but it isn't a kill.
        let table = operatorsTable([
            .make(testSuiteOutcome: .timeout, killingTests: .init(tests: [], count: 0, isComplete: false)),
            .make(testSuiteOutcome: .failed),
            .make(testSuiteOutcome: .passed),
        ])

        XCTAssertEqual(table.columns.map(\.title), ["File", "Applied Mutation Operator", "Mutation Test Result"])
    }

    func test_aKillOnlySuspectTestsFailedFor_isMarkedSuspectOnly() {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let order = FailedTestLine.FailedTest(name: "order()", location: "OrderTests.swift:4:5")

        let cells = operatorsTable([
            .make(
                testSuiteOutcome: .failed,
                killingTests: .init(tests: [timing], count: 1, isComplete: false),
                killedOnlyBySuspectTests: true
            ),
            .make(
                testSuiteOutcome: .failed,
                killingTests: .init(tests: [timing, order], count: 2, isComplete: true),
                killedOnlyBySuspectTests: true
            ),
            .make(testSuiteOutcome: .failed, killingTests: .init(tests: [timing, order], count: 2, isComplete: true)),
        ]).columns.last?.rows.map(\.value)

        XCTAssertEqual(cells, ["timing() (suspect only)", "timing() (+1) (suspect only)", "timing() (+1)"])
    }

    func test_aLongTestName_isCutTo60Characters() {
        let sixtyCharacters = String(repeating: "a", count: 58) + "()"
        let sixtyOneCharacters = String(repeating: "b", count: 59) + "()"
        let killedBy = { (name: String, count: Int) in
            MuterTestReport.AppliedMutationOperator.make(
                testSuiteOutcome: .failed,
                killingTests: .init(tests: [.init(name: name, location: nil)], count: count, isComplete: count == 1)
            )
        }

        let cells = operatorsTable([
            killedBy(sixtyCharacters, 1),
            killedBy(sixtyOneCharacters, 1),
            killedBy(sixtyOneCharacters, 2),
        ]).columns.last?.rows.map(\.value)

        let cutName = String(repeating: "b", count: 59) + "…"
        XCTAssertEqual(cells, [sixtyCharacters, cutName, cutName + " (+1)"])
        XCTAssertEqual(cutName.count, 60)
    }

    func test_mutationScoreTable() {
        let expectedCLITable = CLITable(padding: 3, columns: [
            CLITable.Column(title: "File", rows: [
                CLITable.Row(value: "file1.swift"),
                CLITable.Row(value: "file2.swift"),
                CLITable.Row(value: "file3.swift"),
                CLITable.Row(value: "file 4.swift"),
            ]),
            CLITable.Column(title: "# of Introduced Mutants", rows: [
                CLITable.Row(value: "3"),
                CLITable.Row(value: "2"),
                CLITable.Row(value: "3"),
                CLITable.Row(value: "1"),
            ]),
            CLITable.Column(title: "Mutation Score", rows: [
                CLITable.Row(value: "66"),
                CLITable.Row(value: "100"),
                CLITable.Row(value: "33"),
                CLITable.Row(value: "0"),
            ]),
        ])

        let generatedCLITable = generateMutationScoresCLITable(from: fileReports, coloringFunction: { $0 })

        XCTAssertEqual(generatedCLITable, expectedCLITable)
    }

    func test_coloringTestResults() {
        let rows = [
            CLITable.Row(value: "passed"),
            CLITable.Row(value: "failed"),
        ]

        let coloredRows = applyMutationTestResultsColor(to: rows)

        XCTAssertEqual(coloredRows.count, rows.count)
        XCTAssertNotNil(coloredRows.first?.value.contains(rows.first!.value))
        XCTAssertNotNil(coloredRows.last?.value.contains(rows.last!.value))
    }

    func test_coloringTestScore() {
        let rows = [
            CLITable.Row(value: "0"),
            CLITable.Row(value: "26"),
            CLITable.Row(value: "51"),
            CLITable.Row(value: "76"),
        ]

        let coloredRows = applyMutationScoreColor(to: rows)

        XCTAssertEqual(coloredRows.count, rows.count)
        XCTAssertNotNil(coloredRows.first?.value.contains(rows.first!.value))
        XCTAssertNotNil(coloredRows.last?.value.contains(rows.last!.value))
    }

    private func operatorsTable(_ operators: [MuterTestReport.AppliedMutationOperator]) -> CLITable {
        generateAppliedMutationOperatorsCLITable(
            from: [.make(name: "Sum.swift", path: "/tmp/Sum.swift", mutationScore: 50, appliedOperators: operators)],
            coloringFunction: { $0 }
        )
    }
}
