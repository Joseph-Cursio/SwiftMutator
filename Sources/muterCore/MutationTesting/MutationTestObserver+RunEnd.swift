import Foundation

extension MutationTestObserver {
    /// Writes `summary` beside the results file (`RunSummary.path`), replacing an earlier session's, or in the log
    /// folder once a write to that file failed. One that can't be written is left out: the results file holds
    /// everything it says. Only a run that gets past its baseline finishes or ends early, so only such a run writes
    /// one.
    func writeSummary(_ summary: RunSummary) {
        guard let path = RunSummary.path(besideResultsFile: resultsFilePath, loggingDirectory: loggingDirectory)
        else { return }
        try? writeFile(String(lossyUTF8: summary.json), path)
    }

    /// Makes the run's checks first, so the reports can show them (`MutationTestOutcome.checks`): with a `failUnder`,
    /// the verdict on the score (`ScoreGate`), with `--baseline`, the verdict on the survivors against its file
    /// (`NewSurvivorsCheck`), and on the score against its file's with `--max-score-drop` (`ScoreDropCheck`), and with
    /// `--max-doubtful-kills`, the verdict on the kills (`DoubtfulKillsCheck`), which the run then exits with. Then
    /// saves the reports, then the baseline file `--write-baseline` asks for, then the summary, which records the
    /// verdicts too. Then says the run finished, and prints its report, or where it went, or for a run of one mutant
    /// (`--mutant`) what it changes, its tests' log and its verdict, and where a requested report went; then where each
    /// other report went (`MutationTestOutcome.reports`), where the baseline file went, and where each result is; and
    /// last the verdicts.
    func mutationTestingFinished(_ finished: MutationTestOutcome) {
        var outcome = finished
        let checks = Self.checks(of: outcome)
        self.checks = checks
        outcome.checks = checks.isEmpty ? nil : checks
        let reporter = runOptions.reportOptions.reporter
        let reportPath = runOptions.reportOptions.path ?? ""
        let report = reporter.report(from: outcome)
        let didSave = ReportWriter.save(report, to: reportPath, using: fileManager)
        let others = saveOtherReports(of: outcome, besides: { $0 }, after: didSave ? [reportPath] : [])
        let baselineFile = runOptions.writeBaseline.map {
            BaselineFileSaving.save(outcome, to: $0, version: Self.version(of: outcome), using: fileManager)
        }
        writeSummary(RunSummary(
            of: outcome,
            ended: .finished,
            report: didSave ? reportPath : nil,
            checks: checks,
            reports: others.filter(\.saved).map(\.path)
        ))

        if let oneMutantRun {
            logger.oneMutantTested(oneMutantRun, reports: (reportPath.isEmpty ? [] : [(reportPath, didSave)]) + others)
            baselineFile.map(logger.baselineFileSaved)
            resultsFilePath.map(logger.resultsFileKept(atPath:))
            say(checks)
            return
        }
        logger.mutationTestingFinished(
            report: report,
            reportPath: reportPath,
            isExportingReport: !reportPath.isEmpty,
            didSaveReport: didSave,
            scoreLine: MuterTestReport.scoreLine(of: outcome),
            suspectWarning: KillingTestSummary.warning(for: outcome),
            buildErrorWarning: outcome.buildErrorWarning,
            unprovenKillWarning: outcome.unprovenKillWarning,
            otherReports: others
        )
        baselineFile.map(logger.baselineFileSaved)
        resultsFilePath.map(logger.resultsFileKept(atPath:))
        say(checks)
    }

    /// The verdicts, last: the score's, the survivors', the score's against the baseline file's, then the kills'.
    func say(_ checks: RunChecks) {
        checks.scoreGate.map(logger.scoreGateChecked)
        checks.newSurvivors.map(logger.newSurvivorsChecked)
        checks.scoreDrop.map(logger.scoreDropChecked)
        checks.doubtfulKills.map(logger.doubtfulKillsChecked)
    }

    /// The checks the run of `outcome` asked for: with its `failUnder`, the score's; with `--baseline`'s file, the
    /// survivors', and with `--max-score-drop` too, the score's against the file's; and with `--max-doubtful-kills`,
    /// the kills'. Each not checked, as a run that `endedEarly` says why it stopped itself.
    static func checks(of outcome: MutationTestOutcome, endedEarly: Bool = false) -> RunChecks {
        RunChecks(
            scoreGate: outcome.failUnder.map {
                ScoreGate(failUnder: $0, judging: outcome, unless: endedEarly ? .endedEarly : nil)
            },
            newSurvivors: outcome.baseline.map {
                NewSurvivorsCheck(
                    baseline: $0,
                    maxNewSurvivors: outcome.maxNewSurvivors,
                    judging: outcome,
                    version: version(of: outcome),
                    unless: endedEarly ? .endedEarly : nil
                )
            },
            scoreDrop: outcome.baseline.flatMap { baseline in
                outcome.maxScoreDrop.map {
                    ScoreDropCheck(
                        baseline: baseline,
                        maxScoreDrop: $0,
                        judging: outcome,
                        unless: endedEarly ? .endedEarly : nil
                    )
                }
            },
            doubtfulKills: outcome.maxDoubtfulKills.map {
                DoubtfulKillsCheck(maxDoubtfulKills: $0, judging: outcome, unless: endedEarly ? .endedEarly : nil)
            }
        )
    }

    /// The SwiftMutator version that tested `outcome`, as its results header records it, or else this one.
    static func version(of outcome: MutationTestOutcome) -> String {
        outcome.run?.swiftMutator.version ?? muterCore.version
    }

    /// Saves each of `outcome`'s other reports (`MutationTestOutcome.reports`), in its own format, at the path `path`
    /// gives for its own, and gives where each went and whether it was saved; none is told of each mutant as it
    /// finishes, as only `-f`'s reporter prints while the run goes. A report `path` gives no path for is skipped.
    ///
    /// One that is the same file as one saved before it, `saved`'s or another of these, isn't saved, and is said as
    /// one that couldn't be: the checks before the run compare paths, and two that differ only in case are one file on
    /// a volume that ignores it, which is known only once the first is there.
    func saveOtherReports(
        of outcome: MutationTestOutcome,
        besides path: (String) -> String?,
        after saved: [String]
    ) -> [(path: String, saved: Bool)] {
        var saved = saved
        return outcome.reports.compactMap { request in
            guard let requestedPath = path(request.path) else { return nil }
            guard !saved.contains(where: { ResultsFile.isSameFile(requestedPath, $0) }) else {
                return (requestedPath, false)
            }
            let report = request.format.reporter.report(from: outcome)
            let didSave = ReportWriter.save(report, to: requestedPath, using: fileManager)
            if didSave { saved.append(requestedPath) }
            return (requestedPath, didSave)
        }
    }

    /// Writes what was tested to a partial report beside each requested one, `-o`'s and each other's, never replacing
    /// it, and says what was tested, and the command that continues the run: SwiftMutator's own arguments, resuming
    /// from the results file. Without a requested report there is no partial one: the summary and the results file say
    /// what was tested, and a report printed to the terminal would run to thousands of lines. A run of one mutant
    /// (`--mutant`) can't be resumed, and gets no such command: the same command tests it again. With a `failUnder`,
    /// `--baseline` or `--max-doubtful-kills`, the summary records that each check wasn't made, and nothing is said of
    /// it: the run's end says why it stopped, and it exits for that. It saves no baseline file, and says so.
    func mutationTestingEndedEarly(_ earlyEnd: EarlyEnd) {
        var partialReport: (path: String, saved: Bool)?
        var otherPartialReports: [(path: String, saved: Bool)] = []
        if !earlyEnd.outcome.mutations.isEmpty {
            if let path = PartialReport.path(besides: runOptions.reportOptions.path) {
                let report = runOptions.reportOptions.reporter.report(from: earlyEnd.outcome)
                partialReport = (path, ReportWriter.save(report, to: path, using: fileManager))
            }
            otherPartialReports = saveOtherReports(
                of: earlyEnd.outcome,
                besides: PartialReport.path(besides:),
                after: partialReport.flatMap { $0.saved ? [$0.path] : nil } ?? []
            )
        }
        let checks = Self.checks(of: earlyEnd.outcome, endedEarly: true)
        writeSummary(RunSummary(
            of: earlyEnd.outcome,
            ended: earlyEnd.reason,
            report: partialReport.flatMap { $0.saved ? $0.path : nil },
            checks: checks,
            endDetail: earlyEnd.detail,
            reports: otherPartialReports.filter(\.saved).map(\.path)
        ))
        let continueCommand = runOptions.mutant != nil ? nil : resultsFilePath.map {
            ResumeHint.command(
                continuing: commandLineArguments,
                from: $0,
                since: sinceMergeBase,
                chosenSeed: runOptions.sample.flatMap { $0.seedIsChosen ? $0.seed : nil }
            )
        }
        logger.mutationTestingEndedEarly(
            earlyEnd,
            partialReports: (partialReport.map { [$0] } ?? []) + otherPartialReports,
            resultsFile: resultsFilePath,
            continueCommand: continueCommand,
            baselineFile: runOptions.writeBaseline.map {
                .leftOut(path: $0, because: "the run stopped before it finished")
            }
        )
    }
}
