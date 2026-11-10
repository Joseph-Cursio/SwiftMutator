@testable import muterCore
// Rainbow's settings are static vars that nothing guards: `@preconcurrency` lets these tests change them unchecked,
// which is safe because XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import XCTest

/// The reports a run saves besides `-f`'s (`MutationTestOutcome.reports`): at its end, and beside each when it stops.
final class MutationTestObserverOtherReportsTests: MuterTestCase {
    private var options = Run.Options.make()
    private lazy var sut = MutationTestObserver(runOptions: options)
    private let others = [
        ReportRequest(format: .markdown, path: "/out/summary.md"),
        ReportRequest(format: .json, path: "/out/report.json"),
    ]

    override func setUp() {
        super.setUp()

        Rainbow.outputTarget = .console
        Rainbow.enabled = false
        fileManager.currentDirectoryPathToReturn = "/"
    }

    private func outcome(reports: [ReportRequest]) -> MutationTestOutcome {
        MutationTestOutcome(mutations: [.make(testSuiteOutcome: .failed), .make()], reports: reports)
    }

    // Each in its own format, after -o's, and said after it; the summary records them apart from -o's.
    func test_aFinishedRun_savesEachOtherReport_inItsFormat_afterOutputs() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        let outcome = outcome(reports: others)

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertEqual(
            fileManager.paths.filter { $0.hasPrefix("/out/") }.removingRepeats(),
            ["/out/report.txt", "/out/summary.md", "/out/report.json"]
        )
        XCTAssertEqual(fileManager.createdFiles["/out/summary.md"], Data(MarkdownReporter().report(from: outcome).utf8))
        // As JSON, whose dictionaries' keys come in no set order.
        let json = try JSONSerialization.jsonObject(with: XCTUnwrap(fileManager.createdFiles["/out/report.json"]))
        let expected = try JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8))
        XCTAssertEqual(json as? [String: AnyHashable], expected as? [String: AnyHashable])
        XCTAssertEqual(printer.linesPassed.suffix(4), [
            "📝 Report generated: \("/out/report.txt".bold)",
            "📝 Report generated: \("/out/summary.md".bold)",
            "📝 Report generated: \("/out/report.json".bold)",
            "💾 Each mutant's result is in \("/logs/results.jsonl".bold)",
        ])
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertEqual(summary.report, "/out/report.txt")
        XCTAssertEqual(summary.reports, ["/out/summary.md", "/out/report.json"])
    }

    // Without -o, -f's report is still the one printed, and the others are only saved.
    func test_withoutOutput_theFormatsReportIsPrinted_andTheOthersSaved() throws {
        try sut.start()
        let outcome = outcome(reports: [others[0]])

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "📝 SwiftMutator's report\n\n\(PlainTextReporter().report(from: outcome))",
            "📝 Report generated: \("/out/summary.md".bold)",
        ])
    }

    // One that can't be saved is said, and changes nothing else: the results file holds what it would.
    func test_anOtherReportThatCantBeSaved_isSaid_andLeftOutOfTheSummary() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        fileManager.createFileToReturn = false

        runEvents.send(.mutationTestingFinished(outcome(reports: [others[0]])))

        XCTAssertTrue(printer.linesPassed.contains("⚠️ Could not save the report to /out/summary.md"))
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertNil(summary.reports)
        XCTAssertFalse(String(decoding: summary.json, as: UTF8.self).contains("\"reports\""))
    }

    // Two paths the checks before the run take for two files, but that are one, as two that differ only in case are
    // on a volume that ignores it: the first saved is kept, and the other is said as not saved.
    func test_anOtherReportThatIsAFileSavedBeforeIt_isntSaved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = folder.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link"), withDestinationURL: real
        )
        // As -o's report is once saved; the saves here are pretend.
        let report = real.appendingPathComponent("report.md").path
        XCTAssertTrue(FileManager.default.createFile(atPath: report, contents: Data()))
        let alias = folder.appendingPathComponent("link/report.md").path
        options = .make(reportURL: URL(fileURLWithPath: report))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingFinished(outcome(reports: [
            ReportRequest(format: .markdown, path: alias), others[1],
        ])))

        XCTAssertNil(fileManager.createdFiles[alias])
        XCTAssertNotNil(fileManager.createdFiles["/out/report.json"])
        XCTAssertTrue(printer.linesPassed.contains("⚠️ Could not save the report to \(alias)"), "\(printer.linesPassed)")
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertEqual(summary.reports, ["/out/report.json"])
    }

    // A run of one mutant says where each went after its block, -o's first.
    func test_aRunOfOneMutant_saysWhereEachReportWent() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        try sut.start()
        runEvents.send(.oneMutantTested(.make()))

        runEvents.send(.mutationTestingFinished(outcome(reports: [others[0]])))

        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "📝 Report generated: \("/out/report.txt".bold)",
            "📝 Report generated: \("/out/summary.md".bold)",
        ])
    }

    // Each gets a partial report of its own beside it, without -o too, never replacing it.
    func test_anEarlyEnd_writesAPartialReportBesideEachOtherReport() throws {
        current.commandLineArguments = ["run", "--report", "markdown:/out/summary.md"]
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        let earlyEnd = EarlyEnd(
            reason: .interrupted,
            detail: "SIGINT",
            outcome: outcome(reports: others),
            discovered: 4,
            reused: 0
        )

        runEvents.send(.mutationTestingEndedEarly(earlyEnd))

        XCTAssertEqual(
            fileManager.createdFiles["/out/summary.partial.md"],
            Data(MarkdownReporter().report(from: earlyEnd.outcome).utf8)
        )
        XCTAssertNotNil(fileManager.createdFiles["/out/report.partial.json"])
        XCTAssertFalse(fileManager.paths.contains("/out/summary.md"), "\(fileManager.paths)")
        XCTAssertEqual(Array(standardError.linesPassed.prefix(3)), [
            "⏹ Stopped by SIGINT after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "📝 Partial report: \("/out/summary.partial.md".bold)",
            "📝 Partial report: \("/out/report.partial.json".bold)",
        ])
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertNil(summary.report)
        XCTAssertEqual(summary.reports, ["/out/summary.partial.md", "/out/report.partial.json"])
    }

    // As for -o's: with no mutant tested, the results file and the summary say all there is.
    func test_anEarlyEndWithNothingTested_writesNoPartialOtherReport() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        let earlyEnd = EarlyEnd(
            reason: .interrupted,
            detail: "SIGINT",
            outcome: MutationTestOutcome(reports: others),
            discovered: 4,
            reused: 0
        )

        runEvents.send(.mutationTestingEndedEarly(earlyEnd))

        XCTAssertFalse(fileManager.paths.contains { $0.hasPrefix("/out/") }, "\(fileManager.paths)")
        XCTAssertFalse(standardError.linesPassed.contains { $0.contains("Partial report") })
        let summary = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertNil(summary.reports)
    }
}

private extension Array where Element: Equatable {
    /// Without an element that repeats the one before it, as a save checks, removes and writes one path.
    func removingRepeats() -> [Element] {
        enumerated().compactMap { index, element in index > 0 && self[index - 1] == element ? nil : element }
    }
}
