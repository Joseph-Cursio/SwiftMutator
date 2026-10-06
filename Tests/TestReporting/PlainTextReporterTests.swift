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

    func test_killingTestsSection() {
        let plainText = PlainTextReporter().report(from: .withKillingTests)

        XCTAssertTrue(plainText.contains("\nKilling Tests\n"))
        AssertSnapshot(plainText)
    }

    func test_killingTestsSection_withTooFewFiles_saysNoVerdictWasMade() throws {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let outcome = MutationTestOutcome.make(mutations: (1 ... 3).map { file in
            .make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/tmp/project/File\(file).swift", position: 3),
                killingTests: .init(tests: [timing], count: 1, isComplete: true)
            )
        })

        let plainText = PlainTextReporter().report(from: outcome)

        XCTAssertTrue(plainText.contains(
            "\nSuspect tests are looked for once 10 files have a killed mutant that names a test; this report has 3.\n"
        ))
        XCTAssertEqual(try suspectCells(in: plainText), ["timing()": "-"])
        XCTAssertFalse(PlainTextReporter().report(from: .withKillingTests).contains("Suspect tests are looked for"))
    }

    func test_killingTestsSection_marksEachSuspectTest() throws {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let outcome = MutationTestOutcome.make(mutations: (1 ... 10).map { file in
            .make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/tmp/project/File\(file).swift", position: 3),
                killingTests: .init(
                    tests: [.init(name: "focused\(file)()", location: "File\(file)Tests.swift:3:5"), timing],
                    count: 2,
                    isComplete: true
                )
            )
        })

        let cells = try suspectCells(in: PlainTextReporter().report(from: outcome))

        XCTAssertEqual(cells.count, 10)
        XCTAssertEqual(cells["timing()"], "yes")
        XCTAssertEqual(Set(cells.filter { $0.key != "timing()" }.values), ["-"])
    }

    /// The line `swift-quality` and `run-bench.sh` grep the killed count from must stay the only one that reads
    /// "killed" and a number, whatever else the report says.
    func test_onlyTheScoreSentence_matchesKilledAndANumber() throws {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let suspectKills = (1 ... 12).map { file in
            MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .failed,
                point: .make(filePath: "/tmp/project/Sources/Timing\(file).swift", position: 4),
                killingTests: .init(tests: [timing], count: file.isMultiple(of: 3) ? 2 : 1, isComplete: file > 4)
            )
        }
        let outcome = MutationTestOutcome.make(
            mutations: MutationTestOutcome.withKillingTests.mutations + suspectKills,
            coverage: .make(percent: 40)
        )

        let plainText = PlainTextReporter().report(from: outcome)

        XCTAssertTrue(plainText.contains("\nKilling Tests\n"))
        XCTAssertTrue(plainText.contains("yes"), "the report has a suspect test")
        let killedAndANumber = try NSRegularExpression(pattern: "killed [0-9]+")
        let matching = plainText.components(separatedBy: "\n").filter { line in
            killedAndANumber.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        XCTAssertEqual(matching, ["Of the 31 mutants introduced into your code, your test suite killed 29."])
    }
}

private extension PlainTextReporterTests {
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
}
