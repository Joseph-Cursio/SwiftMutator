import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// `swift-mutator report --report format:path`: the other reports it saves, each checked as `-o`'s is, on results
/// files in a temporary folder.
final class ReportCommandOtherReportsTests: MuterTestCase {
    private var directory = ""
    private var resultsPath: String { "\(directory)/results.jsonl" }

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try makeTemporaryDirectory()
        try write(
            ResultsHeader.make(),
            MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed),
            MutantResult.make(path: "Sources/Alpha.swift", line: 3, outcome: .failed),
            ResultsEnd.make(),
            to: resultsPath
        )
    }

    // After setUpWithError, which XCTest calls first: MuterTestCase installs the spies in both.
    override func setUp() {
        super.setUp()

        // Real files: the spy's contentsOfDirectory can't tell a folder from a file.
        current.fileManager = FileManager.default
    }

    // Each in its own format, never on standard output, which holds -f's report alone; each said on standard error.
    func test_eachOtherReport_isSavedInItsFormat_andSaid() async throws {
        let markdown = "\(directory)/summary.md"
        let html = "\(directory)/report.html"

        try await report(resultsPath, "-f", "json", "--report", "markdown:\(markdown)", "--report", "html:\(html)")

        let saved = try String(contentsOfFile: markdown, encoding: .utf8)
        XCTAssertTrue(saved.hasPrefix("## Mutation testing\n\n**Mutation score: 50% (1 killed, 1 survived)**"), saved)
        XCTAssertTrue(try String(contentsOfFile: html, encoding: .utf8).contains("<html"))
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data((printer.linesPassed.first ?? "").utf8)))
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "Report saved to \(markdown)",
            "Report saved to \(html)",
        ])
        XCTAssertFalse(
            standardError.linesPassed.contains { $0.hasPrefix("Mutation score:") },
            "the score is said only for -o's report: \(standardError.linesPassed)"
        )
    }

    // -o's report and its score line first, then the others; the summary lists the others apart.
    func test_withOutput_andASummary_theOthersFollow_andTheSummaryListsThem() async throws {
        let output = "\(directory)/report.txt"
        let markdown = "\(directory)/summary.md"
        let summaryPath = "\(directory)/summary.json"

        try await report(resultsPath, "-o", output, "--report", "markdown:\(markdown)", "--summary", summaryPath)

        XCTAssertEqual(printer.linesPassed, [])
        XCTAssertEqual(standardError.linesPassed.suffix(4), [
            "Mutation score: 50% (1 killed, 1 survived)",
            "Report saved to \(output)",
            "Report saved to \(markdown)",
            "Summary saved to \(summaryPath)",
        ])
        let data = try Data(contentsOf: URL(fileURLWithPath: summaryPath))
        let summary = try JSONDecoder().decode(RunSummary.self, from: data)
        XCTAssertEqual(summary.report, output)
        XCTAssertEqual(summary.reports, [markdown])
    }

    // As for -o, before anything is printed: saving replaces whatever is there.
    func test_anOtherReportOverTheResultsFile_orAFolder_isRefused() async throws {
        await assertRefused(
            try await report(resultsPath, "--report", "markdown:\(resultsPath)"),
            MuterError.literal(
                reason: "\(resultsPath) is the results file the report is made from: choose another --report path"
            )
        )
        await assertRefused(
            try await report(resultsPath, "--report", "markdown:\(directory)"),
            MuterError.literal(reason: "\(directory) is a folder: name the file to save the report to")
        )
        XCTAssertTrue(try String(contentsOfFile: resultsPath, encoding: .utf8).contains(#""kind":"end""#))
    }

    // Two spellings of one file, which only the file system can tell are one: a hard link, as a different case gives
    // on a volume that ignores it.
    func test_anOtherReportOverTheSummary_orOutput_isRefused() async throws {
        let output = "\(directory)/report.txt"
        XCTAssertTrue(FileManager.default.createFile(atPath: output, contents: Data("old".utf8)))
        try FileManager.default.linkItem(atPath: output, toPath: "\(directory)/link.txt")

        await assertRefused(
            try await report(resultsPath, "-o", output, "--report", "markdown:\(directory)/link.txt"),
            MuterError.literal(
                reason: "The report and --report markdown:\(directory)/link.txt can't both be saved to \(output)"
            )
        )
        await assertRefused(
            try await report(resultsPath, "--report", "markdown:\(output)", "--summary", "\(directory)/link.txt"),
            MuterError.literal(reason: "--report markdown:\(output) and the summary can't both be saved to \(output)")
        )
    }

    // As -o's: the results file still holds everything, so nothing more is said.
    func test_whenAnOtherReportCannotBeSaved_itFails() async throws {
        // A file where its folder would be, which no folder can be made in place of.
        XCTAssertTrue(FileManager.default.createFile(atPath: "\(directory)/notAFolder", contents: nil))
        let missing = "\(directory)/notAFolder/summary.md"

        await assertRefused(
            try await report(resultsPath, "-o", "\(directory)/report.txt", "--report", "markdown:\(missing)"),
            MuterError.literal(reason: "SwiftMutator could not save the report to \(missing)")
        )
    }

    /// Runs `swift-mutator report` with `arguments`.
    private func report(_ arguments: String...) async throws {
        let command = try MuterCommand.parseAsRoot(["report"] + arguments)
        guard let report = command as? Report else {
            XCTFail("Expected the report command, got \(command)")
            return
        }
        try await report.run()
    }

    /// Checks that `expression` throws `expected`, and that nothing is printed on either output.
    private func assertRefused(
        _ expression: @autoclosure () async throws -> Void,
        _ expected: MuterError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await AssertThrowsError(try await expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? MuterError, expected, file: file, line: line)
        }
        XCTAssertEqual(printer.linesPassed, [], file: file, line: line)
        XCTAssertEqual(standardError.linesPassed, [], file: file, line: line)
    }

    private func write(_ records: any Encodable..., to path: String) throws {
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
