@testable import muterCore
import TestingExtensions
import XCTest

/// The Stryker report (`-f stryker`): mutation-testing-elements JSON, the same for the same outcome and files.
final class StrykerReporterTests: MuterTestCase {
    private typealias Fixture = ToolReportFixture

    override func setUp() {
        super.setUp()
        current.readSourceFile = Fixture.read
    }

    private func report(_ outcome: MutationTestOutcome) -> String {
        StrykerReporter(swiftMutatorVersion: "1.2.3").report(from: outcome)
    }

    private func decoded(_ outcome: MutationTestOutcome) throws -> StrykerReport {
        try JSONDecoder().decode(StrykerReport.self, from: Data(report(outcome).utf8))
    }

    // Every status, each kill's tests and duration, the columns in UTF-16 units, a ternary over three lines, a file
    // that can't be read, one outside the project, and one no test ran.
    func test_everyOutcome() {
        AssertSnapshot(report(Fixture.everyOutcome))
    }

    func test_statuses_andWhy() throws {
        let mutants = try decoded(Fixture.everyOutcome).files.values.flatMap(\.mutants)
        let byId = Dictionary(uniqueKeysWithValues: mutants.map { ($0.id, $0) })

        let statuses = mutants.map { "\($0.id) \($0.status.rawValue)" }.sorted()
        XCTAssertEqual(statuses, [
            "Sources/Other.swift:4:9 ChangeLogicalConnector CompileError",
            "Sources/Rules.swift:15:20 RemoveSideEffects NoCoverage",
            "Sources/Rules.swift:2:25 RelationalOperatorReplacement Killed",
            "Sources/Rules.swift:2:39 FlipBooleanLiteral Killed",
            "Sources/Rules.swift:3:14 RelationalBoundary CompileError",
            "Sources/Rules.swift:3:14 RelationalOperatorReplacement Survived",
            "Sources/Rules.swift:8:12 SwapTernary Timeout",
            "mutant 8 Survived",
        ])
        XCTAssertEqual(byId["Sources/Rules.swift:2:39 FlipBooleanLiteral"]?.statusReason?.contains("crashed"), true)
        XCTAssertEqual(
            byId["Sources/Rules.swift:3:14 RelationalBoundary"]?.statusReason?.hasPrefix("Left out of the build"),
            true
        )
        XCTAssertNil(byId["Sources/Other.swift:4:9 ChangeLogicalConnector"]?.statusReason)
        XCTAssertEqual(byId["Sources/Rules.swift:2:25 RelationalOperatorReplacement"]?.killedBy, [
            "RulesTests.test_allows()", "RulesTests.test_equal()",
        ])
        XCTAssertEqual(byId["Sources/Rules.swift:2:25 RelationalOperatorReplacement"]?.duration, 1250)
        XCTAssertEqual(byId["Sources/Rules.swift:15:20 RemoveSideEffects"]?.replacement, "", "nothing in its place")
    }

    // Each test once, under the one file "", as a results line records no test's file.
    func test_theKillingTests_areDefinedOnce() throws {
        let report = try decoded(Fixture.everyOutcome)

        let tests = [
            StrykerReport.Test(id: "RulesTests.test_allows()", name: "RulesTests.test_allows()"),
            StrykerReport.Test(id: "RulesTests.test_equal()", name: "RulesTests.test_equal()"),
        ]
        XCTAssertEqual(report.testFiles, ["": StrykerReport.TestFile(tests: tests)])
        XCTAssertNil(try decoded(Fixture.outcome([Fixture.mutant(.passed, line: 3, column: 14)])).testFiles)
    }

    // `==` is at byte 25 and unit 24; the ternary and the removed statement, placed where they end, start where their
    // code does; a file that can't be read keeps its bytes, and embeds no text.
    func test_columns_countUTF16Units_whenTheFileIsRead() throws {
        let files = try decoded(Fixture.everyOutcome).files
        let rules = try XCTUnwrap(files["Sources/Rules.swift"])
        let equal = try XCTUnwrap(rules.mutants.first { $0.mutatorName == "RelationalOperatorReplacement" })
        XCTAssertEqual(equal.location, StrykerReport.Location(
            start: .init(line: 2, column: 24), end: .init(line: 2, column: 26)
        ))
        let ternary = try XCTUnwrap(rules.mutants.first { $0.mutatorName == "SwapTernary" })
        XCTAssertEqual(ternary.location, .init(start: .init(line: 6, column: 5), end: .init(line: 8, column: 12)))
        let removed = try XCTUnwrap(rules.mutants.first { $0.mutatorName == "RemoveSideEffects" })
        XCTAssertEqual(removed.location, .init(start: .init(line: 15, column: 5), end: .init(line: 15, column: 20)))
        XCTAssertEqual(rules.source, Fixture.rules)

        let other = try XCTUnwrap(files["Sources/Other.swift"])
        XCTAssertEqual(other.source, "")
        XCTAssertEqual(other.mutants.first?.location.start, .init(line: 4, column: 9))
        XCTAssertEqual(files["Sources/Unrun.swift"], .init(language: "swift", source: "func unrun() {}\n", mutants: []))
        XCTAssertNotNil(files["/elsewhere/Shared.swift"])
    }

    // A file changed since it was tested still has its text as it is now.
    func test_aFileChangedSinceItWasTested_embedsTodaysText() throws {
        var outcome = Fixture.outcome([Fixture.mutant(.passed, line: 3, column: 14)])
        outcome.sourceDigests = ["Sources/Rules.swift": "another file's hash"]

        XCTAssertEqual(try decoded(outcome).files["Sources/Rules.swift"]?.source, Fixture.rules)
    }

    // The mutants of a file by line, column and id, whatever order they were tested in.
    func test_isTheSame_whateverOrderTheMutantsCameIn() {
        let keyed = Fixture.everyOutcome.mutations.filter { $0.key != nil }

        XCTAssertEqual(report(Fixture.outcome(keyed.reversed())), report(Fixture.outcome(keyed)))
    }

    func test_withoutMutants() throws {
        let report = try decoded(MutationTestOutcome())

        XCTAssertEqual(report.schemaVersion, "2")
        XCTAssertEqual(report.thresholds, .init(high: 80, low: 60))
        XCTAssertEqual(report.framework, .init(name: "SwiftMutator", version: "1.2.3"))
        XCTAssertEqual(report.files, [:])
        XCTAssertNil(report.projectRoot)
        XCTAssertNil(report.testFiles)
    }
}
