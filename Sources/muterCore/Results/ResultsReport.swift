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
    /// `--report`: the other reports to save, each in its own format, with their paths resolved; never on standard
    /// output. Never the run's `reports:`, which the header records: saving them would replace the run's own files.
    let reports: [ReportRequest]
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
    /// `--baseline`: the baseline file, as given, whose survivors the report's are compared with
    /// (`NewSurvivorsCheck`); nil compares none. As `failUnder`, never anything the run was given.
    let baselinePath: String?
    /// `--max-new-survivors`: how many new survivors pass the comparison with `baselinePath`'s file.
    let maxNewSurvivors: Int
    /// `--max-score-drop`: how many points the score may fall below `baselinePath`'s file's (`ScoreDropCheck`); nil
    /// compares none.
    let maxScoreDrop: Double?
    /// `--max-doubtful-kills`: how many kills the results' evidence may leave in doubt (`DoubtfulKillsCheck`); nil
    /// counts none.
    let maxDoubtfulKills: Int?
    /// `--write-baseline`: where to save the report's survivors as a baseline file (`BaselineFile`), made absolute as
    /// the flags are read; nil saves none. Only a whole run's results make one, a merge of every shard's too, when the
    /// shards discovered the same mutants.
    let writeBaselinePath: String?

    init(
        format: ReportFormat,
        outputPath: String?,
        reports: [ReportRequest] = [],
        summaryPath: String? = nil,
        failUnder: Double? = nil,
        propertyTests: [String]? = nil,
        triagePath: String? = nil,
        baselinePath: String? = nil,
        maxNewSurvivors: Int = 0,
        maxScoreDrop: Double? = nil,
        maxDoubtfulKills: Int? = nil,
        writeBaselinePath: String? = nil
    ) {
        self.format = format
        self.outputPath = outputPath
        self.reports = reports
        self.summaryPath = summaryPath
        self.failUnder = failUnder
        self.propertyTests = propertyTests
        self.triagePath = triagePath
        self.baselinePath = baselinePath
        self.maxNewSurvivors = maxNewSurvivors
        self.maxScoreDrop = maxScoreDrop
        self.maxDoubtfulKills = maxDoubtfulKills
        self.writeBaselinePath = writeBaselinePath
    }

    /// Makes the report from the results files `paths` name: each the file itself, or the log folder of one of a run's
    /// sessions. A file that a resumed session's folder names, and another of the `paths` gives too, is reported once.
    /// One file is reported as it is, unless it is a shard's; shards' files, the shards of one split, are merged,
    /// one alone too, `forcing` build and toolchain differences through, and the project files `ignoring`'s globs
    /// match. Standard output holds the report alone
    /// (and, in the Xcode format, its warnings), so `-f json > report.json` is valid JSON; what the files hold, the
    /// report's warning of suspect tests, where the report and each of `reports` went, and last the verdict on its
    /// score against `failUnder`, are said on standard error.
    ///
    /// Gives the status `report` exits with, nil for 0: for a run that stopped on an error, the one the run itself
    /// exited with (`ExitCode.exitStatus(afterRunFailedWith:)`), so a script that checks the report fails as one that
    /// checked the run would; for shards whose merge lacks results, a stopped shard's, or else 4
    /// (`MergedShards.exitStatus`); otherwise 2 when a check failed (`RunChecks`): the score against `failUnder`
    /// (`ScoreGate`), or the survivors against `baselinePath`'s file (`NewSurvivorsCheck`), which check what the file
    /// holds, of a run that was interrupted too, and say so; the score against the file's (`ScoreDropCheck`), which
    /// only a whole run's results compare; or the doubtful kills (`DoubtfulKillsCheck`). An error's status wins, and
    /// nothing is checked.
    ///
    /// The baseline file is read before the results files, and refused (`BaselineRefused`), before anything is said,
    /// when it can't be read, or records another scope than the results' header, unless they compare no survivors:
    /// those of a run of one mutant, one that stopped on an error, and shards whose merge lacks results.
    @discardableResult
    func make(from paths: [String], forcing: Bool = false, ignoring: [String] = []) throws -> ExitCode? {
        let files = Self.withoutNotedRepeats(try paths.map { try ResultsFile.locate(at: $0, using: fileManager) })
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
        // Now, so a typo doesn't wait for the results to be read. The same file as `writeBaselinePath` is read before
        // it is replaced.
        let baseline = try baselinePath.map { try BaselineFile.load(at: $0, using: fileManager) }
        // A file whose run stopped before its first mutant has no result: it is said, and left out, and with no other
        // file, `report` exits as that run did.
        var stopped: [ResultsStopped] = []
        let read = try files.compactMap { file -> (path: String, recorded: RecordedResults)? in
            guard let data = fileManager.contents(atPath: file) else {
                throw ResultsFileError.unreadable(path: file)
            }
            do {
                return (path: file, recorded: try RecordedResults.read(data, path: file))
            } catch let ResultsFileError.stoppedBeforeFirstMutant(_, record) {
                stopped.append(record)
                record.lines(path: file).forEach(errorPrinter)
                return nil
            }
        }
        guard !read.isEmpty else {
            // Nothing is reported, but what was asked for and not done is said, as for a report of results.
            if let baselinePath {
                errorPrinter(
                    "The survivors aren't compared with the baseline file \(baselinePath): the run stopped before its "
                        + "first mutant."
                )
            }
            if let baselinePath, maxScoreDrop != nil {
                errorPrinter(
                    "The score isn't compared with the baseline file \(baselinePath)'s: the run stopped before its "
                        + "first mutant."
                )
            }
            if maxDoubtfulKills != nil {
                errorPrinter("Doubtful kills aren't counted: the run stopped before its first mutant.")
            }
            if let writeBaselinePath {
                let because = "the run stopped before its first mutant"
                errorPrinter(BaselineFileSaving.leftOut(path: writeBaselinePath, because: because).plainLine)
            }
            return stopped.first?.exitStatus
        }
        let stoppedStatus = stopped.first?.exitStatus
        if read.count == 1, let only = read.first, only.recorded.headers.last?.shard == nil {
            return try reportOne(only, stoppedStatus: stoppedStatus, baseline: baseline)
        }
        let merged = try MergedShards.merge(read, forcing: forcing, ignoring: ignoring)
        return try reportMerged(merged, stoppedStatus: stoppedStatus, baseline: baseline)
    }

    /// Reports the one results file `only` holds, unless it is a shard's, checked against `baseline`'s file, if given,
    /// and gives the status `make` exits with; `stoppedStatus` is that of another file given, whose run stopped before
    /// its first mutant. The baseline file's scope is compared only with that of results whose survivors are: not of a
    /// run of one mutant (`--mutant`), which records every operator, and coverage skipped, and which a run doesn't
    /// compare either, nor of one that stopped on an error, which exits as it did.
    private func reportOne(
        _ only: (path: String, recorded: RecordedResults),
        stoppedStatus: ExitCode?,
        baseline: BaselineFile?
    ) throws -> ExitCode? {
        let status = only.recorded.exitStatus
        let stopped = status != nil || stoppedStatus != nil
        if let baseline, let header = only.recorded.headers.last, header.mutant == nil, !stopped {
            try BaselineRefused.check(BaselineScope(header: header), against: baseline, subject: "these results")
        }
        var outcome = only.recorded.mutationTestOutcome(resultsFile: only.path)
        if let propertyTests { outcome.propertyTests = propertyTests }
        outcome.triage = try triageFile(of: outcome)
        let ended = only.recorded.sessions.last?.end
        let notChecked: NewSurvivorsCheck.NotChecked? = stopped ? .stoppedOnAnError : nil
        let checks = RunChecks(
            scoreGate: failUnder.map {
                ScoreGate(
                    failUnder: $0,
                    judging: outcome,
                    unless: stopped ? .stoppedOnAnError : nil,
                    progress: only.recorded.unfinishedProgress
                )
            },
            newSurvivors: baseline.map {
                newSurvivorsCheck($0, of: outcome, unless: notChecked, progress: only.recorded.unfinishedProgress)
            },
            scoreDrop: scoreDropCheck(
                baseline,
                of: outcome,
                unless: stopped ? .stoppedOnAnError : nil,
                progress: only.recorded.unfinishedProgress
            ),
            doubtfulKills: maxDoubtfulKills.map {
                DoubtfulKillsCheck(
                    maxDoubtfulKills: $0,
                    judging: outcome,
                    // With mutants left, a resume tests them, then the suspect kills again alone; with none left, it
                    // reruns nothing, so the kills are counted as they are.
                    unless: stopped ? .stoppedOnAnError : only.recorded.unfinishedProgress.map { _ in .unfinished },
                    progress: only.recorded.unfinishedProgress
                )
            }
        )
        let incomplete = if stopped {
            "the run stopped on an error"
        } else if ended?.reason != .finished {
            "the run didn't finish"
        } else {
            String?.none
        }
        try report(
            outcome,
            saying: only.recorded.statusLines(path: only.path),
            ended: ended,
            checks: checks,
            incomplete: incomplete
        )
        return status ?? stoppedStatus ?? checks.exitStatus
    }

    /// Reports the `merged` shards, checked against `baseline`'s file, if given, and gives the status `make` exits
    /// with; `stoppedStatus` is that of a file given whose run stopped before its first mutant.
    private func reportMerged(
        _ merged: MergedShards,
        stoppedStatus: ExitCode?,
        baseline: BaselineFile?
    ) throws -> ExitCode? {
        let status = merged.exitStatus
        let lacksResults = status != nil || stoppedStatus != nil
        // As for one file: a merge that lacks results compares no survivors, and exits for that.
        if let baseline, !lacksResults {
            try BaselineRefused.check(
                BaselineScope(header: merged.reference.header),
                against: baseline,
                subject: "these results"
            )
        }
        var outcome = merged.mutationTestOutcome()
        if let propertyTests { outcome.propertyTests = propertyTests }
        outcome.triage = try triageFile(of: outcome)
        let notChecked: NewSurvivorsCheck.NotChecked? = lacksResults ? .lacksResults : nil
        let checks = RunChecks(
            scoreGate: failUnder.map {
                ScoreGate(failUnder: $0, judging: outcome, unless: lacksResults ? .lacksResults : nil)
            },
            newSurvivors: baseline.map { newSurvivorsCheck($0, of: outcome, unless: notChecked) },
            // Shards that discovered different mutants may each lack results for some, which `--write-baseline`
            // refuses too, so their score isn't a whole run's.
            scoreDrop: scoreDropCheck(
                baseline,
                of: outcome,
                unless: lacksResults ? .lacksResults : (merged.discoveriesAgree ? nil : .discoveriesDiffer)
            ),
            // A shard that didn't finish lacks results, so isn't counted either.
            doubtfulKills: maxDoubtfulKills.map {
                DoubtfulKillsCheck(
                    maxDoubtfulKills: $0,
                    judging: outcome,
                    unless: lacksResults ? .lacksResults : nil,
                    suspectsByMutant: lacksResults ? nil : merged.suspectTestsByMutant
                )
            }
        )
        let incomplete = if lacksResults {
            "the merged report lacks results"
        } else if !merged.discoveriesAgree {
            "the shards' runs didn't discover the same mutants"
        } else if merged.ending?.reason != .finished, outcome.shards == nil {
            "a shard's run didn't finish"
        } else {
            String?.none
        }
        try report(outcome, saying: merged.statusLines(), ended: merged.ending, checks: checks, incomplete: incomplete)
        return status ?? stoppedStatus ?? checks.exitStatus
    }

    /// The verdict on `outcome`'s survivors against `baseline`'s, not checked for the reason `unless` gives;
    /// `progress` is that of a run that didn't finish.
    private func newSurvivorsCheck(
        _ baseline: BaselineFile,
        of outcome: MutationTestOutcome,
        unless notChecked: NewSurvivorsCheck.NotChecked?,
        progress: ScoreGate.Progress? = nil
    ) -> NewSurvivorsCheck {
        NewSurvivorsCheck(
            baseline: baseline,
            maxNewSurvivors: maxNewSurvivors,
            judging: outcome,
            version: MutationTestObserver.version(of: outcome),
            unless: notChecked,
            progress: progress
        )
    }

    /// With `maxScoreDrop`, the verdict on `outcome`'s score against `baseline`'s, not checked for the reason `unless`
    /// gives, nor for the results of a run that didn't finish, whose `progress` it says; nil without either.
    private func scoreDropCheck(
        _ baseline: BaselineFile?,
        of outcome: MutationTestOutcome,
        unless notChecked: ScoreDropCheck.NotChecked?,
        progress: ScoreGate.Progress? = nil
    ) -> ScoreDropCheck? {
        guard let baseline, let maxScoreDrop else { return nil }
        return ScoreDropCheck(
            baseline: baseline,
            maxScoreDrop: maxScoreDrop,
            judging: outcome,
            unless: notChecked,
            progress: progress
        )
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

    /// Prints or saves the report of `outcome`, which shows `checks`, and saves each of `reports`, and the baseline
    /// file, unless the results are `incomplete`, as that clause says; then says `status` and the rest on standard
    /// error, and saves its summary, of a run that `ended` so, if asked to; then says the verdicts of `checks`, last,
    /// as a run does. A report that can't be saved stops it before the rest is said: the results file still holds it
    /// all. A baseline file that can't be saved is only said, as a run says it.
    private func report(
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
