import Foundation

extension ResultsReport {
    /// Refuses, before anything is read, a path the report, the other reports, the summary or the baseline file would
    /// be saved to that would destroy one of the results `files`, or a folder, and two of them saved to one file.
    func checkSavingAll(from files: [String]) throws {
        if let outputPath {
            try checkSaving(.report, to: outputPath, from: files)
        }
        for request in reports {
            try checkSaving(.other, to: request.path, from: files)
        }
        if let summaryPath {
            try checkSaving(.summary, to: summaryPath, from: files)
        }
        if let writeBaselinePath {
            try checkSaving(.baseline, to: URL.expandingTilde(writeBaselinePath), from: files)
        }
        try checkTheSavedFilesDiffer()
    }

    /// Prints or saves the report of `outcome`, which shows `checks`, and saves each of `reports`, and the baseline
    /// file, unless the results are `incomplete`, as that clause says; then says `status` and the rest on standard
    /// error, and saves its summary, of a run that `ended` so, if asked to; then says the verdicts of `checks`, last,
    /// as a run does. A report that can't be saved stops it before the rest is said: the results file still holds it
    /// all. A baseline file that can't be saved is only said, as a run says it.
    func report(
        _ checked: MutationTestOutcome,
        saying status: [String],
        ended: ResultsEnd?,
        checks: RunChecks,
        incomplete: String?
    ) throws {
        var outcome = checked
        outcome.checks = checks.isEmpty ? nil : checks
        let reporter = format.reporter
        // As a run does when each mutant finishes: only the Xcode format prints anything, a warning for each survivor.
        for mutation in outcome.mutations {
            reporter.newMutationTestOutcomeAvailable(outcomeWithFlush: (mutation: mutation, fflush: flushStandardOut))
        }
        let report = reporter.report(from: outcome)
        if let outputPath {
            try save(report, to: outputPath)
        }
        // Only `-f`'s reporter is told of each mutant: the others' would print their warnings too.
        for request in reports {
            try save(request.format.reporter.report(from: outcome), to: request.path)
        }
        let baselineFile = writeBaselinePath.map {
            BaselineFileSaving.save(
                outcome,
                to: $0,
                version: MutationTestObserver.version(of: outcome),
                using: fileManager,
                unless: incomplete
            )
        }
        if case .saved = baselineFile {
            // As after a report: two spellings of one new file are known to be one only once it's there.
            try checkTheSavedFilesDiffer()
        }
        if outputPath == nil {
            printer(report)
        }
        // The report comes before what's said about it, should both go to one place.
        flushStandardOut()
        status.forEach(errorPrinter)
        // As a run ends with it, without the run's emoji: it is said of the report, as the status lines are.
        KillingTestSummary.warning(for: outcome).map(errorPrinter)
        outcome.buildErrorWarning.map(errorPrinter)
        outcome.unprovenKillWarning.map(errorPrinter)
        if let outputPath {
            // The report itself isn't printed, so its score is.
            errorPrinter(MuterTestReport.scoreLine(of: outcome))
            errorPrinter("Report saved to \(outputPath)")
        }
        reports.forEach { errorPrinter("Report saved to \($0.path)") }
        baselineFile.map { errorPrinter($0.plainLine) }
        if let summaryPath {
            try saveSummary(of: outcome, to: summaryPath, ended: ended, checks: checks)
        }
        sayVerdicts(of: checks)
    }

    /// Saves the summary of `outcome`, of a run that `ended` so, which shows `checks`, at `summaryPath`, and says so.
    private func saveSummary(
        of outcome: MutationTestOutcome,
        to summaryPath: String,
        ended: ResultsEnd?,
        checks: RunChecks
    ) throws {
        let summary = RunSummary(
            of: outcome,
            ended: ended?.reason,
            endDetail: ended?.detail,
            report: outputPath,
            reports: reports.map(\.path),
            checks: checks
        )
        guard ReportWriter.save(String(lossyUTF8: summary.json), to: summaryPath, using: fileManager)
        else {
            throw MuterError.literal(reason: "SwiftMutator could not save the summary to \(summaryPath)")
        }
        errorPrinter("Summary saved to \(summaryPath)")
    }

    /// Says the verdicts of `checks`, last, as a run does.
    private func sayVerdicts(of checks: RunChecks) {
        checks.scoreGate?.line.map(errorPrinter)
        if let newSurvivors = checks.newSurvivors {
            newSurvivors.versionNotice.map(errorPrinter)
            newSurvivors.lines.forEach(errorPrinter)
        }
        checks.scoreDrop?.line.map(errorPrinter)
        checks.doubtfulKills?.lines.forEach(errorPrinter)
    }

    /// Saves `report` at `path`, then checks the files saved still differ: two spellings of one new file, which differ
    /// only in case on a volume that ignores it, are known to be one only once it's there.
    private func save(_ report: String, to path: String) throws {
        guard ReportWriter.save(report, to: path, using: fileManager) else {
            throw MuterError.literal(reason: "SwiftMutator could not save the report to \(path)")
        }
        try checkTheSavedFilesDiffer()
    }

    /// What `report` saves: the report itself, at `-o`, another report, at `--report`, the summary, at `--summary`, or
    /// the baseline file, at `--write-baseline`.
    private enum Saved {
        case report
        case other
        case summary
        case baseline

        /// What it is called in a refusal.
        var noun: String {
            switch self {
            case .report, .other: "report"
            case .summary: "summary"
            case .baseline: "baseline file"
            }
        }

        /// What the option that gives its path is called in a refusal.
        var pathName: String {
            switch self {
            case .report: "output path"
            case .other: "--report path"
            case .summary: "summary path"
            case .baseline: "--write-baseline path"
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
            throw MuterError.literal(reason: "\(path) is a folder: name the file to save the \(saved.noun) to")
        }
    }

    /// Refuses to save one of the report, the other reports, the summary and the baseline file over another.
    private func checkTheSavedFilesDiffer() throws {
        // Appended one at a time: as one sum of optional arrays of tuples, Xcode 26's compiler gives up on it.
        var saved: [(name: String, path: String)] = []
        if let outputPath {
            saved.append((name: "the report", path: outputPath))
        }
        saved += reports.map { (name: "--report \($0)", path: $0.path) }
        if let summaryPath {
            saved.append((name: "the summary", path: summaryPath))
        }
        if let writeBaselinePath {
            saved.append((name: "the baseline file", path: URL.expandingTilde(writeBaselinePath)))
        }
        for later in saved.indices {
            for earlier in saved.indices
                where earlier < later && ResultsFile.isSameFile(saved[earlier].path, saved[later].path) {
                let first = saved[earlier].name
                throw MuterError.literal(
                    reason: first.prefix(1).uppercased() + first.dropFirst()
                        + " and \(saved[later].name) can't both be saved to \(saved[earlier].path)"
                )
            }
        }
    }
}
