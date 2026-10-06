@testable import muterCore
import Rainbow
import TestingExtensions
import XCTest

final class PlainTextReporterTests: ReporterTestCase {
    override func setUp() {
        super.setUp()

        // Rainbow is smart, it knows if the stdout is Xcode or the console.
        // We want it to be the console, otherwise the test results are going to differ when running from Xcode vs
        // console
        Rainbow.outputTarget = .console
        Rainbow.enabled = false
    }

    func test_plainTextReporterWithCoverageData() {
        let plainText = PlainTextReporter()
            .report(
                from: .make(
                    mutations: outcomes,
                    coverage: .make(percent: 1)
                )
            )

        AssertSnapshot(plainText)
    }

    func test_plainTextReporterWithoutCoverageData() {
        let plainText = PlainTextReporter()
            .report(
                from: .make(
                    mutations: outcomes,
                    coverage: .null
                )
            )

        AssertSnapshot(plainText)
    }

    func test_killedByColumn_keepsEveryRowAligned() throws {
        let killing = { (names: [String], count: Int) in
            MutationTestOutcome.KillingTests(
                tests: names.map { .init(name: $0, location: "SumTests.swift:3:5") },
                count: count,
                isComplete: names.count == count
            )
        }
        let longName = #""adding every number in a long list gives the same total in any order""#
        typealias KillingTests = MutationTestOutcome.KillingTests
        let mutation = { (outcome: TestSuiteOutcome, file: String, line: Int, killingTests: KillingTests?) in
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: outcome,
                point: .make(filePath: "/tmp/project/\(file)", position: .init(integerLiteral: line)),
                killingTests: killingTests
            )
        }
        let outcome = MutationTestOutcome.make(mutations: [
            mutation(.failed, "Sum.swift", 3, killing(["sum()"], 1)),
            mutation(.failed, "Sum.swift", 12, killing([longName, "sum()"], 4)),
            mutation(.passed, "Sum.swift", 20, nil),
            mutation(.runtimeError, "Total.swift", 7, .noneNamed),
            mutation(.timeout, "Total.swift", 9, killing([], 0)),
        ])

        let plainText = PlainTextReporter().report(from: outcome)

        let lines = plainText.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("File ") && $0.contains("Mutation Test Result") })
        let table = Array(lines[header...].prefix { !$0.isEmpty })
        let title = try XCTUnwrap(table[0].range(of: "Killed By"))
        let offset = table[0].distance(from: table[0].startIndex, to: title.lowerBound)
        XCTAssertEqual(table.map { String($0.dropFirst(offset)) }, [
            "Killed By",
            "---------",
            "sum()",
            String(longName.prefix(59)) + "… (+3)",
            "-",
            "(none named)",
            "-",
        ])
        XCTAssertTrue(table.allSatisfy { $0.prefix(offset).hasSuffix("   ") })

        // Colour codes, as a terminal gets them, take no room.
        Rainbow.enabled = true
        defer { Rainbow.enabled = false }
        let colouredText = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(colouredText.contains("\u{1B}["))
        let visibleText = colouredText
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        XCTAssertEqual(visibleText, plainText)
    }
}
