@testable import muterCore
import XCTest

/// What the console says of the reports a run saves besides `-f`'s.
final class LoggerOtherReportsTests: MuterTestCase {
    private let sut = Logger()

    // After -o's line, and before the warnings, which stay the run's last word on its score.
    func test_mutationTestingFinished_saysWhereEachOtherReportWent_afterOutputs() {
        sut.mutationTestingFinished(
            report: "",
            reportPath: "/out/report.txt",
            isExportingReport: true,
            didSaveReport: true,
            scoreLine: "Mutation score: 50% (1 killed, 1 survived)",
            suspectWarning: "a warning",
            otherReports: [("/out/summary.md", true), ("/out/report.json", false)]
        )

        XCTAssertEqual(printer.linesPassed, [
            "🏁 SwiftMutator finished running!",
            "📊 Mutation score: 50% (1 killed, 1 survived)",
            "📝 Report generated: \("/out/report.txt".bold)",
            "📝 Report generated: \("/out/summary.md".bold)",
            "⚠️ Could not save the report to /out/report.json",
            "⚠️ a warning",
        ])
    }

    func test_oneMutantTested_saysWhereEachReportWent() {
        sut.oneMutantTested(.make(), reports: [("/out/report.txt", true), ("/out/summary.md", false)])

        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "📝 Report generated: \("/out/report.txt".bold)",
            "⚠️ Could not save the report to /out/summary.md",
        ])
    }

    func test_mutationTestingEndedEarly_saysWhereEachPartialReportWent() {
        sut.mutationTestingEndedEarly(
            .make(),
            partialReports: [("/out/report.partial.txt", true), ("/out/summary.partial.md", false)],
            resultsFile: nil,
            continueCommand: nil
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by a signal after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "📝 Partial report: \("/out/report.partial.txt".bold)",
            "⚠️ Could not save the partial report to /out/summary.partial.md",
        ])
    }
}
