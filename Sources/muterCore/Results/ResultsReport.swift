import Foundation

/// `swift-mutator report`: a run's report in any format, made from its results file. For a finished run it's the
/// run's own report; for one that stopped, or is still going, it reports what the file holds so far.
struct ResultsReport {
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.printer)
    private var printer: Printer
    @Dependency(\.errorPrinter)
    private var errorPrinter: Printer
    @Dependency(\.flushStandardOut)
    private var flushStandardOut: Flush

    let format: ReportFormat
    /// Where to save the report; nil prints it on standard output.
    let outputPath: String?

    init(format: ReportFormat, outputPath: String?) {
        self.format = format
        self.outputPath = outputPath
    }

    /// Makes the report from the results file `path` names: the file itself, or a run's log folder that holds it.
    /// Standard output holds the report alone (and, in the Xcode format, its warnings), so `-f json > report.json` is
    /// valid JSON; what the file holds, and where the report went, are said on standard error.
    func make(from path: String) throws {
        let file = try ResultsFile.find(at: path, using: fileManager)
        if let outputPath {
            try checkSaving(to: outputPath, from: file)
        }
        guard let data = fileManager.contents(atPath: file) else {
            throw ResultsFileError.unreadable(path: file)
        }
        let recorded = try RecordedResults.read(data, path: file)
        let outcome = recorded.mutationTestOutcome()
        let reporter = format.reporter
        // As a run does when each mutant finishes: only the Xcode format prints anything, a warning for each survivor.
        for mutation in outcome.mutations {
            reporter.newMutationTestOutcomeAvailable(outcomeWithFlush: (mutation: mutation, fflush: flushStandardOut))
        }
        let report = reporter.report(from: outcome)
        if let outputPath {
            guard ReportWriter.save(report, to: outputPath, using: fileManager) else {
                throw MuterError.literal(reason: "SwiftMutator could not save the report to \(outputPath)")
            }
        } else {
            printer(report)
        }
        // The report comes before what's said about it, should both go to one place.
        flushStandardOut()
        recorded.statusLines(path: file).forEach(errorPrinter)
        if let outputPath {
            errorPrinter("Report saved to \(outputPath)")
        }
    }

    /// Refuses an `outputPath` that saving the report at would destroy, before anything is printed: saving replaces
    /// whatever is there, so the results file the report is made from, or a folder and everything in it.
    private func checkSaving(to outputPath: String, from file: String) throws {
        if ResultsFile.isSameFile(outputPath, file) {
            throw MuterError.literal(
                reason: "\(outputPath) is the results file the report is made from: choose another output path"
            )
        }
        if (try? fileManager.contentsOfDirectory(atPath: outputPath)) != nil {
            throw MuterError.literal(reason: "\(outputPath) is a folder: name the file to save the report to")
        }
    }
}
