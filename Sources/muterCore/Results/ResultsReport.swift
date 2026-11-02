import Foundation

/// `swift-mutator report`: a run's report in any format, made from its results file. For a finished run it's the
/// run's own report; for one that stopped, or is still going, it reports what the file holds so far. The results files
/// of a split's shards are merged into the whole run's report (`MergedShards`).
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

    /// Makes the report from the results files `paths` name: each the file itself, or a run's log folder that holds
    /// it. One file is reported as it is, unless it is a shard's; shards' files, the shards of one split, are merged,
    /// one alone too, `forcing` build and toolchain differences through, and the project files `ignoring`'s globs
    /// match. Standard output holds the report alone
    /// (and, in the Xcode format, its warnings), so `-f json > report.json` is valid JSON; what the files hold, the
    /// report's warning of suspect tests, and where the report went, are said on standard error. Gives whether
    /// `report` exits as a run that stopped on an error.
    @discardableResult
    func make(from paths: [String], forcing: Bool = false, ignoring: [String] = []) throws -> Bool {
        let files = try paths.map { try ResultsFile.find(at: $0, using: fileManager) }
        if let outputPath {
            try checkSaving(to: outputPath, from: files)
        }
        let read = try files.map { file in
            guard let data = fileManager.contents(atPath: file) else {
                throw ResultsFileError.unreadable(path: file)
            }
            return (path: file, recorded: try RecordedResults.read(data, path: file))
        }
        if read.count == 1, let only = read.first, only.recorded.headers.last?.shard == nil {
            try report(only.recorded.mutationTestOutcome(), saying: only.recorded.statusLines(path: only.path))
            return only.recorded.stoppedOnAnError
        }
        let merged = try MergedShards.merge(read, forcing: forcing, ignoring: ignoring)
        try report(merged.mutationTestOutcome(), saying: merged.statusLines())
        return merged.lacksResults
    }

    /// Prints or saves the report of `outcome`, then says `status` and the rest on standard error.
    private func report(_ outcome: MutationTestOutcome, saying status: [String]) throws {
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
        status.forEach(errorPrinter)
        // As a run ends with it, without the run's emoji: it is said of the report, as the status lines are.
        KillingTestSummary.warning(for: outcome).map(errorPrinter)
        if let outputPath {
            errorPrinter("Report saved to \(outputPath)")
        }
    }

    /// Refuses an `outputPath` that saving the report at would destroy, before anything is printed: saving replaces
    /// whatever is there, so a results file the report is made from, or a folder and everything in it.
    private func checkSaving(to outputPath: String, from files: [String]) throws {
        if files.contains(where: { ResultsFile.isSameFile(outputPath, $0) }) {
            let file = files.count == 1 ? "the results file" : "one of the results files"
            throw MuterError.literal(
                reason: "\(outputPath) is \(file) the report is made from: choose another output path"
            )
        }
        if (try? fileManager.contentsOfDirectory(atPath: outputPath)) != nil {
            throw MuterError.literal(reason: "\(outputPath) is a folder: name the file to save the report to")
        }
    }
}
