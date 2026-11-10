import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    // CI can gate on a results file it already has. The report and the status come first, and the verdict last, on
    // standard error; the status is the threshold's own, and ArgumentParser prints nothing more.
    // The run's header records its propertyTests, which the report splits the kills by; --property-tests replaces
    // them, and without either there is no such section.
    func test_propertyTests_splitTheKills_asTheHeaderRecordsThem_unlessTheFlagGivesOthers() async throws {
        let ordered = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let configured = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], propertyTests: ["*Properties*"]
        )
        let lines: [any Encodable] = [
            ResultsHeader.make(mutantsDiscovered: 2, mutantsToTest: 2, configuration: configured),
            MutantResult.make(path: "Sources/Sort.swift", line: 3, killedBy: [ordered]),
            MutantResult.make(path: "Sources/Sum.swift", line: 3, killedBy: [sum]),
            ResultsEnd.make(recorded: 2),
        ]
        try write(lines, to: resultsPath)

        try await report(resultsPath)
        try await report(resultsPath, "--property-tests", "sum()", "--property-tests", "ordered()")
        try await report(resultsPath, "-f", "json")

        XCTAssertEqual(printer.linesPassed.count, 3)
        let (recorded, flagged) = (printer.linesPassed[0], printer.linesPassed[1])
        XCTAssertTrue(recorded.contains(#"matches "*Properties*"."#), recorded)
        XCTAssertTrue(recorded.contains("examples alone were recorded killing 1 (50%), properties alone 1 (50%)"))
        XCTAssertTrue(flagged.contains(#"matches "sum()" or "ordered()"."#), flagged)
        XCTAssertTrue(flagged.contains("examples alone were recorded killing 0 (0%), properties alone 2 (100%)"))
        XCTAssertNotNil(try parsedJSON(printer.linesPassed[2])["propertyKillSummary"])

        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try await report(resultsPath)
        XCTAssertFalse(try XCTUnwrap(printer.linesPassed.last).contains("Examples and Properties"))
    }

    func test_anEmptyPropertyTestsGlob_isAUsageError() {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["report", resultsPath, "--property-tests", ""])) { error in
            XCTAssertEqual(
                MuterCommand.message(for: error),
                "--property-tests: a glob can't be empty, as it would match no test."
            )
        }
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["run", "--property-tests", ""]))
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--property-tests", "*Properties*"]))
    }
}
