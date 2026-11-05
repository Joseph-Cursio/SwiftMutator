import ArgumentParser
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
    /// Where to save the run's `summary.json` (`RunSummary`); nil saves none.
    let summaryPath: String?
    /// `--fail-under`: the percent below which the report's score fails it (`ScoreGate`); nil checks none. Never the
    /// run's `failUnder`, which a CI job that didn't ask for it would then be failed by.
    let failUnder: Double?
    /// `--property-tests`: the globs that pick out property tests, in place of those the run's header records; nil
    /// keeps the header's.
    let propertyTests: [String]?
    /// `--triage`: the triage file, which must be there; nil looks for `muter.triage.yml` in the run's project, then
    /// in the current folder, and reports without labels if neither has one.
    let triagePath: String?

    init(
        format: ReportFormat,
        outputPath: String?,
        summaryPath: String? = nil,
        failUnder: Double? = nil,
        propertyTests: [String]? = nil,
        triagePath: String? = nil
    ) {
        self.format = format
        self.outputPath = outputPath
        self.summaryPath = summaryPath
        self.failUnder = failUnder
        self.propertyTests = propertyTests
        self.triagePath = triagePath
    }

    /// Makes the report from the results files `paths` name: each the file itself, or the log folder of one of a run's
    /// sessions. A file that a resumed session's folder names, and another of the `paths` gives too, is reported once.
    /// One file is reported as it is, unless it is a shard's; shards' files, the shards of one split, are merged,
    /// one alone too, `forcing` build and toolchain differences through, and the project files `ignoring`'s globs
    /// match. Standard output holds the report alone
    /// (and, in the Xcode format, its warnings), so `-f json > report.json` is valid JSON; what the files hold, the
    /// report's warning of suspect tests, where the report went, and last the verdict on its score against
    /// `failUnder`, are said on standard error.
    ///
    /// Gives the status `report` exits with, nil for 0: for a run that stopped on an error, the one the run itself
    /// exited with (`ExitCode.exitStatus(afterRunFailedWith:)`), so a script that checks the report fails as one that
    /// checked the run would; for shards whose merge lacks results, a stopped shard's, or else 4
    /// (`MergedShards.exitStatus`); otherwise the verdict's (`ScoreGate`), which checks what the file holds, of a run
    /// that was interrupted too, and says so. An error's status wins, and its score isn't checked.
    @discardableResult
    func make(from paths: [String], forcing: Bool = false, ignoring: [String] = []) throws -> ExitCode? {
        let files = Self.withoutNotedRepeats(try paths.map { try ResultsFile.locate(at: $0, using: fileManager) })
        if let outputPath {
            try checkSaving(.report, to: outputPath, from: files)
        }
        if let summaryPath {
            try checkSaving(.summary, to: summaryPath, from: files)
        }
        try checkTheReportAndSummaryDiffer()
        let read = try files.map { file in
            guard let data = fileManager.contents(atPath: file) else {
                throw ResultsFileError.unreadable(path: file)
            }
            return (path: file, recorded: try RecordedResults.read(data, path: file))
        }
        if read.count == 1, let only = read.first, only.recorded.headers.last?.shard == nil {
            var outcome = only.recorded.mutationTestOutcome(resultsFile: only.path)
            if let propertyTests { outcome.propertyTests = propertyTests }
            outcome.triage = try triageFile(of: outcome)
            let status = only.recorded.exitStatus
            let gate = failUnder.map {
                ScoreGate(
                    failUnder: $0,
                    judging: outcome,
                    unless: status == nil ? nil : .stoppedOnAnError,
                    progress: only.recorded.unfinishedProgress
                )
            }
            try report(
                outcome,
                saying: only.recorded.statusLines(path: only.path),
                ended: only.recorded.sessions.last?.end,
                gate: gate
            )
            return status ?? gate?.exitStatus
        }
        let merged = try MergedShards.merge(read, forcing: forcing, ignoring: ignoring)
        var outcome = merged.mutationTestOutcome()
        if let propertyTests { outcome.propertyTests = propertyTests }
        outcome.triage = try triageFile(of: outcome)
        let status = merged.exitStatus
        let gate = failUnder.map {
            ScoreGate(failUnder: $0, judging: outcome, unless: status == nil ? nil : .lacksResults)
        }
        try report(outcome, saying: merged.statusLines(), ended: merged.ending, gate: gate)
        return status ?? gate?.exitStatus
    }

    /// The triage file the report of `outcome` shows, which a broken one refuses: nothing is lost by fixing it and
    /// asking again.
    private func triageFile(of outcome: MutationTestOutcome) throws -> TriageFile? {
        if let triagePath {
            guard let file = try TriageFile.load(at: triagePath, using: fileManager) else {
                throw MuterError.literal(reason: "There is no triage file at \(triagePath).")
            }
            return file
        }
        for folder in [outcome.projectPath, fileManager.currentDirectoryPath] where !folder.isEmpty {
            if let file = try TriageFile.load(at: TriageFile.path(in: folder), using: fileManager) {
                return file
            }
        }
        return nil
    }

    /// The paths of the `found` files, less each that a resumed session's note named and that is the same file as one
    /// given directly, or as one an earlier note named. A glob over a run's log folders, such as `<logs>/*/`, names its
    /// file through the first session's folder and through each resumed session's, which are one file however they
    /// are spelled, as `/tmp` and `/private/tmp` are. A file named twice directly is kept twice, so a shard's file
    /// given twice is still refused.
    private static func withoutNotedRepeats(_ found: [(path: String, isNoted: Bool)]) -> [String] {
        found.indices.compactMap { index in
            let file = found[index]
            let isRepeat = file.isNoted && found.indices.contains { other in
                other != index && (!found[other].isNoted || other < index)
                    && ResultsFile.isSameFile(found[other].path, file.path)
            }
            return isRepeat ? nil : file.path
        }
    }

    /// Prints or saves the report of `outcome`, then says `status` and the rest on standard error, and saves its
    /// summary, of a run that `ended` so, if asked to; then says the verdict of `gate`, last, as a run does.
    private func report(
        _ outcome: MutationTestOutcome,
        saying status: [String],
        ended: ResultsEnd?,
        gate: ScoreGate?
    ) throws {
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
        outcome.buildErrorWarning.map(errorPrinter)
        if let outputPath {
            // The report itself isn't printed, so its score is.
            errorPrinter(MuterTestReport.scoreLine(of: outcome))
            errorPrinter("Report saved to \(outputPath)")
        }
        if let summaryPath {
            // Checked again now that the report exists: two spellings of one new file, which differ only in case on a
            // volume that ignores it, are known to be one only once it's there.
            try checkTheReportAndSummaryDiffer()
            let summary = RunSummary(
                of: outcome,
                ended: ended?.reason,
                endDetail: ended?.detail,
                report: outputPath,
                gate: gate
            )
            guard ReportWriter.save(String(decoding: summary.json, as: UTF8.self), to: summaryPath, using: fileManager)
            else {
                throw MuterError.literal(reason: "SwiftMutator could not save the summary to \(summaryPath)")
            }
            errorPrinter("Summary saved to \(summaryPath)")
        }
        gate?.line.map(errorPrinter)
    }

    /// What `report` saves: the report itself, at `-o`, or the summary, at `--summary`.
    private enum Saved: String {
        case report
        case summary

        /// What the option that gives its path is called in a refusal.
        var pathName: String {
            switch self {
            case .report: "output path"
            case .summary: "summary path"
            }
        }
    }

    /// Refuses a `path` that saving `saved` at would destroy, before anything is printed: saving replaces whatever is
    /// there, so a results file the report is made from, or a folder and everything in it.
    private func checkSaving(_ saved: Saved, to path: String, from files: [String]) throws {
        if files.contains(where: { ResultsFile.isSameFile(path, $0) }) {
            let file = files.count == 1 ? "the results file" : "one of the results files"
            throw MuterError.literal(
                reason: "\(path) is \(file) the report is made from: choose another \(saved.pathName)"
            )
        }
        if (try? fileManager.contentsOfDirectory(atPath: path)) != nil {
            throw MuterError.literal(reason: "\(path) is a folder: name the file to save the \(saved.rawValue) to")
        }
    }

    /// Refuses to save the summary over the report.
    private func checkTheReportAndSummaryDiffer() throws {
        if let outputPath, let summaryPath, ResultsFile.isSameFile(outputPath, summaryPath) {
            throw MuterError.literal(reason: "The report and the summary can't both be saved to \(outputPath)")
        }
    }
}
