@testable import muterCore
import TestingExtensions
import XCTest

extension ReportCommandTests {
    // Standard output holds the report alone, so `-f json > report.json` stays valid JSON: the warning of the run's
    // suspect tests is said on standard error, after what the file holds, and without the run's emoji.
    func test_suspectTests_areSaidOnStandardErrorOnly_withoutEmoji() throws {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let files = (0 ..< 10).map { "Sources/F\($0).swift" }
        let header: [any Encodable] = [ResultsHeader.make(mutantsDiscovered: 11, mutantsToTest: 11)]
        let kills: [any Encodable] = files.map { MutantResult.make(path: $0, line: 3, killedBy: [timing]) }
        let survivorAndEnd: [any Encodable] = [zeta9, ResultsEnd.make(recorded: 11)]
        try write(header + kills + survivorAndEnd, to: resultsPath)
        let outcome = ran(
            MutationTestOutcome(
                mutations: files.map { path in
                    mutation(path, line: 3, .failed, killingTests: .init(tests: [timing], count: 1, isComplete: true))
                } + [mutation("Sources/Zeta.swift", line: 9, .passed)],
                coverage: .null,
                coverageSkipped: true,
                testDuration: 100.5,
                newVersion: ""
            ),
            header: .make(mutantsDiscovered: 11, mutantsToTest: 11)
        )
        let status = "Report of 11 of 11 mutants, from \(resultsPath): the run finished."
        let warning = "1 test may fail whatever the mutant: it failed for mutants in at least 15% of the 10 files "
            + "with a killed mutant (timing() in 10). Without its failures, the mutation score would be 0%, not 90%."

        try report(resultsPath)

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: outcome)])
        XCTAssertEqual(standardError.linesPassed, [status, warning])

        let output = "\(directory)/report.json"
        try report(resultsPath, "-f", "json", "-o", output)

        XCTAssertEqual(
            try parsedJSON(String(contentsOfFile: output, encoding: .utf8)),
            try parsedJSON(JsonReporter().report(from: outcome))
        )
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: outcome)], "nothing more")
        XCTAssertEqual(
            standardError.linesPassed,
            [status, warning, status, warning, "Mutation score: 90% (10 killed, 1 survived)"]
                + ["Report saved to \(output)"]
        )
    }

    // `--summary` saves the run's summary.json, of how its last session ended, naming the report and the file.
    func test_theSummary_isSavedWhereAsked() throws {
        let interrupted = ResultsEnd.make(reason: .interrupted, detail: "SIGTERM")
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, interrupted, to: resultsPath)
        let summaryPath = "\(directory)/summary.json"
        let output = "\(directory)/report.html"

        try report(resultsPath, "-f", "html", "-o", output, "--summary", summaryPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: summaryPath))
        let summary = try JSONDecoder().decode(RunSummary.self, from: data)
        XCTAssertEqual(summary, RunSummary(of: expected, ended: .interrupted, report: output, endDetail: "SIGTERM"))
        XCTAssertEqual(summary.run?.resultsFiles, [resultsPath])
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")
    }

    // Saving replaces whatever is there, so never the results file, nor the report.
    func test_theSummary_isNeverSavedOverTheResultsFile_orTheReport() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/report.txt"

        await AssertThrowsError(try report(resultsPath, "--summary", resultsPath))
        await AssertThrowsError(try report(resultsPath, "-o", output, "--summary", output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertTrue(try String(contentsOfFile: resultsPath, encoding: .utf8).contains(#""kind":"end""#))
    }

    // Two spellings of one new file, on a volume that ignores case, are known to be one only once the report is saved:
    // the summary is then refused, and the report kept.
    func test_theSummary_isNeverSavedOverTheReport_spelledInAnotherCase() async throws {
        let probe = "\(directory)/probe"
        XCTAssertTrue(FileManager.default.createFile(atPath: probe, contents: nil))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(directory)/PROBE"), "This volume tells case apart")
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/Report.txt"

        await AssertThrowsError(try report(resultsPath, "-o", output, "--summary", "\(directory)/report.txt")) {
            let refusal = "The report and the summary can't both be saved to \(output)"
            XCTAssertEqual($0 as? MuterError, .literal(reason: refusal))
        }
        let saved = try String(contentsOfFile: output, encoding: .utf8)
        XCTAssertTrue(saved.contains("Sources/Zeta.swift:9:22 survived"), "the report, not the summary: \(saved)")
    }

    // A refusal names the option whose path it refuses.
    func test_aSummaryPathThatIsAFolder_isRefusedAsTheSummarys() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try report(resultsPath, "--summary", directory)) {
            let refusal = "\(directory) is a folder: name the file to save the summary to"
            XCTAssertEqual($0 as? MuterError, .literal(reason: refusal))
        }
        await AssertThrowsError(try report(resultsPath, "--summary", resultsPath)) {
            let refusal = "\(resultsPath) is the results file the report is made from: choose another summary path"
            XCTAssertEqual($0 as? MuterError, .literal(reason: refusal))
        }
    }

    // The run stopped before any mutant finished.
    func test_aFileWithOnlyItsHeader_givesAnEmptyReport() throws {
        try write(ResultsHeader.make(), to: resultsPath)

        try report(resultsPath, "-f", "json")

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            try parsedJSON(printer.linesPassed.first ?? ""),
            try parsedJSON(JsonReporter().report(from: ran(MutationTestOutcome())))
        )
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 0 of 3 mutants, from \(resultsPath): "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }
}
