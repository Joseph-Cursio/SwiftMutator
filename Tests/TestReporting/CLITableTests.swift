@testable import muterCore
import XCTest

final class CLITableTests: MuterTestCase {
    private let fileColumn = CLITable.Column(title: "File name", rows: [
        CLITable.Row(value: "file 1.swift"),
        CLITable.Row(value: "file2.swift"),
        CLITable.Row(value: "file 3.swift"),
        CLITable.Row(value: "file4.swift"),
    ])

    private let mutationScoreColumn = CLITable.Column(title: "Mutation Score", rows: [
        CLITable.Row(value: "60"),
        CLITable.Row(value: "0"),
        CLITable.Row(value: "100"),
        CLITable.Row(value: "55"),
    ])

    private let numberOfAppliedMutationsColumn = CLITable.Column(title: "# of Generated Mutants", rows: [
        CLITable.Row(value: "1"),
        CLITable.Row(value: "2"),
        CLITable.Row(value: "3"),
        CLITable.Row(value: "4"),
    ])

    private lazy var columns = [
        fileColumn,
        numberOfAppliedMutationsColumn,
        mutationScoreColumn,
    ]

    func test_cliTableWithPaddingOfThree() {
        let expectedCLITable = """
        File name      # of Generated Mutants   Mutation Score
        ---------      ----------------------   --------------
        file 1.swift   1                        60
        file2.swift    2                        0
        file 3.swift   3                        100
        file4.swift    4                        55
        """

        XCTAssertTrue(CLITable(padding: 3, columns: columns).description.contains(expectedCLITable))
    }

    func test_cliTableWithPaddingOfSix() {
        let expectedCLITable = """
        File name         # of Generated Mutants      Mutation Score
        ---------         ----------------------      --------------
        file 1.swift      1                           60
        file2.swift       2                           0
        file 3.swift      3                           100
        file4.swift       4                           55
        """

        XCTAssertTrue(CLITable(padding: 6, columns: columns).description.contains(expectedCLITable))
    }

    func test_differentPaddings() {
        XCTAssertNotEqual(
            CLITable(padding: 4, columns: columns).description,
            CLITable(padding: 3, columns: columns).description
        )
    }

    func test_resizeBasedOnRowContents() {
        XCTAssertEqual(fileColumn.width, 12)
        XCTAssertEqual(numberOfAppliedMutationsColumn.width, 22)
    }

    func test_widthWithEmptyRows() {
        XCTAssertEqual(CLITable.Column(title: "", rows: []).width, 0)

        let emptyColumnWithValues = CLITable.Column(title: "", rows: [CLITable.Row(value: "")])
        XCTAssertEqual(emptyColumnWithValues.width, 0)
    }

    func test_emptyString() {
        XCTAssertEqual(CLITable.Column(title: "", rows: []).description, "")
    }

    func test_aColumnAfterAColouredOne_linesUpWithItsTitle() {
        // Literal colour codes, as Rainbow writes them when stdout is a terminal, so no global Rainbow state is needed.
        let green = "\u{1B}[32m"
        let reset = "\u{1B}[0m"
        let resultColumn = CLITable.Column(title: "Result", rows: [
            CLITable.Row(value: green + "mutant killed (test failure)" + reset),
            CLITable.Row(value: green + "mutant killed" + reset),
        ])
        let table = CLITable(padding: 3, columns: [
            CLITable.Column(title: "File", rows: [
                CLITable.Row(value: "Sum.swift:3"),
                CLITable.Row(value: "Product.swift:12"),
            ]),
            CLITable.Column(title: "Operator", rows: [
                CLITable.Row(value: "RelationalOperatorReplacement"),
                CLITable.Row(value: "SwapTernary"),
            ]),
            resultColumn,
            CLITable.Column(title: "Killed By", rows: [
                CLITable.Row(value: "sum()"),
                CLITable.Row(value: "product() (+2)"),
            ]),
        ])

        XCTAssertEqual(resultColumn.width, "mutant killed (test failure)".count)
        XCTAssertTrue(table.description.contains(green + "mutant killed" + reset))
        let visibleLines = table.description.split(separator: "\n").map {
            $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        }
        let killedByOffset = "Product.swift:12".count + "RelationalOperatorReplacement".count
            + "mutant killed (test failure)".count + 3 * 3
        XCTAssertEqual(
            visibleLines.map { String($0.dropFirst(killedByOffset)) },
            ["Killed By", "---------", "sum()", "product() (+2)"]
        )
    }
}
