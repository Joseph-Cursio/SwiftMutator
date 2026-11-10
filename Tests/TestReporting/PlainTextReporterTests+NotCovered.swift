@testable import muterCore
import TestingExtensions
import XCTest

extension PlainTextReporterTests {
    /// Each test in the Killing Tests table, with its Suspect cell.
    func suspectCells(in plainText: String) throws -> [String: String] {
        let lines = plainText.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("Test ") && $0.hasSuffix("Suspect") })
        let suspectColumn = try XCTUnwrap(lines[header].range(of: "Suspect"))
        let offset = lines[header].distance(from: lines[header].startIndex, to: suspectColumn.lowerBound)
        let rows = lines[(header + 2)...].prefix { !$0.isEmpty && !$0.hasPrefix("These are ") }
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            (String(row.prefix { $0 != " " }), String(row.dropFirst(offset)))
        })
    }

    // A mutant not covered has a section of its own, as nothing can kill it until a test reaches it. A report with none
    // is as it was, as the snapshots above show.
    func test_mutantsNotCovered_areListedApartFromSurvivors() {
        let notCovered = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .noCoverage,
            point: .make(
                mutationOperatorId: .ror,
                filePath: "/project_mutated/Sources/Unreached.swift",
                position: .init(utf8Offset: 0, line: 7, column: 3)
            ),
            snapshot: .make(before: ">", after: "<", description: "changed > to <"),
            key: MutantKey(
                path: "Sources/Unreached.swift", mutationOperatorId: .ror, line: 7, column: 3, occurrence: 0
            )
        )

        let plainText = PlainTextReporter().report(from: .make(mutations: [notCovered]))

        let section = plainText.components(separatedBy: "Mutants Not Covered").last ?? ""
        XCTAssertTrue(section.contains("No test reached this mutant"), plainText)
        XCTAssertTrue(section.contains(":7:3: RelationalOperatorReplacement (changed > to <)"), plainText)
        XCTAssertTrue(plainText.contains("No mutant survived or timed out."), plainText)
        XCTAssertTrue(plainText.contains("1 not covered"), plainText)
    }
}
