import ArgumentParser
import Foundation

/// `swift-mutator report`: a run's report in any format, made from its results file. For a finished run it's the
/// run's own report; for one that stopped, or is still going, it reports what the file holds so far. The results files
/// of a split's shards are merged into the whole run's report (`MergedShards`).
struct ResultsReport {
    @Dependency(\.fileManager)
    var fileManager: FileSystemManager
    @Dependency(\.printer)
    var printer: Printer
    @Dependency(\.errorPrinter)
    var errorPrinter: Printer
    @Dependency(\.flushStandardOut)
    var flushStandardOut: Flush

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
        try checkSavingAll(from: files)
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
            sayWhatIsntDone()
            return stopped.first?.exitStatus
        }
        let stoppedStatus = stopped.first?.exitStatus
        if read.count == 1, let only = read.first, only.recorded.headers.last?.shard == nil {
            return try reportOne(only, stoppedStatus: stoppedStatus, baseline: baseline)
        }
        let merged = try MergedShards.merge(read, forcing: forcing, ignoring: ignoring)
        return try reportMerged(merged, stoppedStatus: stoppedStatus, baseline: baseline)
    }

    /// Says what was asked for and not done when every results file's run stopped before its first mutant: nothing is
    /// reported, but this is said, as for a report of results.
    private func sayWhatIsntDone() {
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
        try report(
            outcome,
            saying: only.recorded.statusLines(path: only.path),
            ended: ended,
            checks: checks,
            incomplete: Self.incompleteness(stopped: stopped, ended: ended)
        )
        return status ?? stoppedStatus ?? checks.exitStatus
    }

    /// Why one results file's results are incomplete, in a clause, as `report(_:saying:ended:checks:incomplete:)`
    /// takes it: its run `stopped` on an error, or `ended` otherwise than finished; nil when they're whole.
    private static func incompleteness(stopped: Bool, ended: ResultsEnd?) -> String? {
        if stopped {
            "the run stopped on an error"
        } else if ended?.reason != .finished {
            "the run didn't finish"
        } else {
            nil
        }
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
}
