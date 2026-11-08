#if os(Linux)
import Glibc
#else
import Darwin.C
#endif
import Foundation
import Rainbow
import SwiftSyntax

final class MutationTestObserver {
    @Dependency(\.logger)
    private var logger: Logger
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.writeFile)
    private var writeFile: WriteFile
    @Dependency(\.flushStandardOut)
    private var flushStdOut: Flush
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.commandLineArguments)
    private var commandLineArguments: [String]

    private(set) var loggingDirectory: String = ""
    /// The run's marker in its log folder, locked from `start()` until the observer goes, so no other run prunes the
    /// folder meanwhile (`RunMarker`); nil when it couldn't be made.
    private var runMarker: RunMarker?
    /// The run's results file, while every result has been written to it.
    private var resultsFilePath: String?
    /// The merge base `--since` compared the working tree with, which the command that continues the run names.
    private var sinceMergeBase: String?
    /// The run of the one mutant `--mutant` tests, which the end of the run prints in place of the report.
    private var oneMutantRun: OneMutantRun?
    /// The finished run's verdict on its score against its `failUnder`, which the run exits with; nil without one,
    /// and for a run that didn't finish.
    private(set) var scoreGate: ScoreGate?
    private let runOptions: Run.Options

    /// The observer's registration with the run's events, from `start()`; it ends when the observer does.
    private var subscription: RunEvents.Subscription?

    init(runOptions: Run.Options) {
        self.runOptions = runOptions
    }

    /// Creates the run's log folder, with the run's marker in it, and observes the run's events.
    func start() throws {
        loggingDirectory = try createLoggingDirectory(
            forProjectAt: fileManager.currentDirectoryPath,
            fileManager: fileManager
        )
        runMarker = RunMarker.hold(in: loggingDirectory)

        subscription = events.observe { [weak self] event in self?.handle(event) }
    }

    /// Removes the run's log folder if the run kept nothing in it. That happens when a run is refused or fails before
    /// its first log. A resumed session that runs no coverage and has nothing left to test keeps its folder, which
    /// holds its note naming the results file (`ResultsFile.noteFileName`). The logs' root, `<project>_muter_logs`,
    /// stays, because another run of the project may be claiming a folder in it at the same moment. The run's marker
    /// counts for nothing, and goes with the folder. Before `start()` there is no folder, and nothing is removed.
    func removeLoggingDirectoryIfEmpty() {
        guard !loggingDirectory.isEmpty else { return }
        if removeFolderIfEmpty(atPath: loggingDirectory, ignoring: [RunMarker.fileName], fileManager: fileManager) {
            runMarker?.release()
        }
    }
}

extension MutationTestObserver {
    func handle(_ event: RunEvent) {
        switch event {
        case .muterLaunched:
            logger.launched()

        case .updateCheckStarted:
            logger.updateCheckStarted()
        case let .updateCheckFinished(newVersion):
            logger.updateCheckFinished(newVersion: newVersion)

        case let .changesSelected(selection):
            sinceMergeBase = selection.mergeBase
            logger.changesSelected(selection, verbose: runOptions.verbose)

        case let .logFoldersPruned(pruning):
            logger.logFoldersPruned(pruning)

        case .projectCopyStarted:
            logger.projectCopyStarted()
        case let .projectCopySkippedVanishedFiles(paths):
            logger.projectCopySkippedVanishedFiles(paths)
        case let .projectCopyFinished(destinationPath):
            logger.projectCopyFinished(destinationPath: destinationPath)

        case .projectCoverageDiscoveryStarted:
            logger.projectCoverageDiscoveryStarted()
        case let .projectCoverageDiscoveryFinished(failure):
            logger.projectCoverageDiscoveryFinished(failureReason: failure?.reason, log: failure?.log)
        case let .projectCoverageTestsFailed(failed):
            logger.projectCoverageTestsFailed(failed)

        case .sourceFileDiscoveryStarted: logger.sourceFileDiscoveryStarted()
        case let .packageSourceFilesUnavailable(reason): logger.packageSourceFilesUnavailable(reason: reason)
        case let .filesToMutateUnmatched(entries): logger.filesToMutateUnmatched(entries)
        case let .buildConditionsUnavailable(reason): logger.buildConditionsUnavailable(reason: reason)
        case let .sourceFileDiscoveryFinished(sourceFileCandidates):
            logger.sourceFileDiscoveryFinished(sourceFileCandidates: sourceFileCandidates, verbose: runOptions.verbose)

        case .mutationsDiscoveryStarted:
            logger.mutationsDiscoveryStarted()
        case let .mutationsDiscoveryFinished(mappings):
            logger.mutationsDiscoveryFinished(mutations: mappings, verbose: runOptions.verbose)
        case let .mutantsSelected(sample, shard, mappings):
            logger.mutationsDiscoveryFinished(
                mutations: mappings,
                verbose: runOptions.verbose,
                sample: sample.map { (selection: $0, seedIsChosen: runOptions.sample?.seedIsChosen ?? false) },
                shard: shard
            )
        case let .mutantsDropped(dropped):
            logger.mutantsDropped(dropped, verbose: runOptions.verbose)

        case let .resumePlanned(summary):
            logger.resumePlanned(summary)
        case .mutationTestingStarted:
            logger.mutationTestingStarted()
        case .mutantRunsStarted:
            logger.mutantRunsStarted()
        case let .stillTesting(still):
            logger.stillTesting(still)
        case let .workersChosen(choice):
            choice.sentence.map(logger.print)
        case let .stopAtFirstFailureTurnedOff(reason):
            logger.stopAtFirstFailureTurnedOff(reason: reason)
        case let .testBundlesNotRunDirectly(reason):
            logger.testBundlesNotRunDirectly(reason: reason)
        case let .timedTestRunStopped(seconds, log):
            logger.timedTestRunStopped(seconds: seconds, log: log)
        case .workersShareUserDefaults:
            logger.workersShareUserDefaults()
        case let .testBundlesWroteInTheProject(path):
            logger.testBundlesWroteInTheProject(path: path)
        case let .buildingAgainWithoutMutants(count):
            logger.buildingAgainWithoutMutants(count: count)
        case let .stoppedTakingOutMutants(builds):
            logger.stoppedTakingOutMutants(afterBuilds: builds)
        case let .mutantsLeftOutOfTheBuild(leftOut):
            logger.mutantsLeftOutOfTheBuild(leftOut)
        case let .controlRunFinished(control):
            logger.controlRunFinished(control)
        case let .activationNotShown(runs):
            logger.activationNotShown(runs: runs)
        case let .unprovenRunsRerunStarted(count):
            logger.unprovenRunsRerunStarted(count: count)
        case let .unprovenRunRerun(mutation, changed):
            // As a timeout's: a verdict that didn't change is no news, and the logger's outcome counts the progress.
            if changed {
                runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
                    outcomeWithFlush: MutationOutcomeWithFlush(mutation: mutation, fflush: flushStdOut)
                )
            }
        case let .unprovenRunsRerunFinished(tally):
            logger.unprovenRunsRerunFinished(tally)
        case let .suspectKillRerunsSkipped(log):
            logger.suspectKillRerunsSkipped(log: log)
        case let .suspectKillRerunsStarted(reruns):
            logger.suspectKillRerunsStarted(reruns)
        case let .suspectKillRerun(mutation, changed):
            // As a timeout's: a verdict that didn't change is no news, and the logger's outcome counts the progress.
            if changed {
                runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
                    outcomeWithFlush: MutationOutcomeWithFlush(mutation: mutation, fflush: flushStdOut)
                )
            }
        case let .suspectKillRerunsFinished(tally):
            logger.suspectKillRerunsFinished(tally)
        case let .timeoutRerunsStarted(reruns):
            logger.timeoutRerunsStarted(reruns)
        case let .timeoutRerunFinished(rerun):
            // A verdict that didn't change is no news. Never the logger's outcome or log, which count the progress
            // again.
            if rerun.changed {
                runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
                    outcomeWithFlush: MutationOutcomeWithFlush(mutation: rerun.rerun, fflush: flushStdOut)
                )
            }
            logger.timeoutRerunFinished(rerun)
        case let .timeoutRerunsFinished(tally):
            logger.timeoutRerunsFinished(tally)
        case let .propertyRerunsStarted(reruns):
            logger.propertyRerunsStarted(reruns)
        case let .propertyRerunsFinished(tally):
            logger.propertyRerunsFinished(tally)
        case let .propertyRerunsSkipped(reason, log):
            logger.propertyRerunsSkipped(reason: reason, log: log)
        case let .runRepeatedAfterLaunchFailure(repeated):
            logger.runRepeatedAfterLaunchFailure(repeated)
        case let .baselineRepeatedAfterLaunchFailure(line, log):
            logger.baselineRepeatedAfterLaunchFailure(line: line, keptFileName: log.keptFileName)
        case let .oneMutantTested(run):
            oneMutantRun = run
        case let .mutationTestingFinished(outcome):
            mutationTestingFinished(outcome)
        case let .mutationTestingEndedEarly(earlyEnd):
            mutationTestingEndedEarly(earlyEnd)

        case let .newMutationTestOutcomeAvailable(mutation):
            runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
                outcomeWithFlush: MutationOutcomeWithFlush(mutation: mutation, fflush: flushStdOut)
            )
            logger.newMutationTestOutcomeAvailable(mutation: mutation)
        case let .newTestLogAvailable(mutationTestLog):
            logger.newMutationTestLogAvailable(mutationTestLog: mutationTestLog)
        case let .resultsFileCreated(path):
            resultsFilePath = path
            logger.resultsFileCreated(atPath: path)
        case let .resultsFileUnavailable(reason):
            // The file, if there is one, lacks every result after the failed write, so the end of the run doesn't name
            // it.
            resultsFilePath = nil
            logger.resultsFileUnavailable(reason: reason)

        case .testPlanFileCreated, .muterMutationTestPlanLoaded, .testPlanSourcesUnchecked, .testPlanSourcesDiffer,
             .testPlanUntestedFilesChanged, .testPlanChangesWaived, .testPlanCopyEdited, .testPlanCopyResolutionChanged:
            handleTestPlanEvent(event)
        }
    }

    /// What a test plan's events say, as they're made or checked.
    private func handleTestPlanEvent(_ event: RunEvent) {
        switch event {
        case let .testPlanFileCreated(created):
            logger.testPlanFileCreated(created)
        case .muterMutationTestPlanLoaded:
            logger.muterMutationTestPlanLoaded()
        case .testPlanSourcesUnchecked:
            logger.testPlanSourcesUnchecked()
        case let .testPlanSourcesDiffer(changes):
            logger.testPlanSourcesDiffer(changes)
        case let .testPlanUntestedFilesChanged(changes):
            logger.testPlanUntestedFilesChanged(changes)
        case let .testPlanChangesWaived(paths):
            logger.testPlanChangesWaived(paths)
        case let .testPlanCopyEdited(paths):
            logger.testPlanCopyEdited(paths)
        case let .testPlanCopyResolutionChanged(changes):
            logger.testPlanCopyResolutionChanged(changes)
        default:
            break
        }
    }

    /// Writes `summary` beside the results file (`RunSummary.path`), replacing an earlier session's, or in the log
    /// folder once a write to that file failed. One that can't be written is left out: the results file holds
    /// everything it says. Only a run that gets past its baseline finishes or ends early, so only such a run writes
    /// one.
    private func writeSummary(_ summary: RunSummary) {
        guard let path = RunSummary.path(besideResultsFile: resultsFilePath, loggingDirectory: loggingDirectory)
        else { return }
        try? writeFile(String(decoding: summary.json, as: UTF8.self), path)
    }

    /// Says the run finished, then prints its report, or where it went, or for a run of one mutant (`--mutant`) what
    /// it changes, its tests' log and its verdict, and where a requested report went; then where each result is; and
    /// last, with a `failUnder`, the verdict on the score (`ScoreGate`), which the run then exits with. The summary
    /// records that verdict too.
    private func mutationTestingFinished(_ outcome: MutationTestOutcome) {
        let reporter = runOptions.reportOptions.reporter
        let reportPath = runOptions.reportOptions.path ?? ""
        let report = reporter.report(from: outcome)
        let didSave = ReportWriter.save(report, to: reportPath, using: fileManager)
        let gate = outcome.failUnder.map { ScoreGate(failUnder: $0, judging: outcome) }
        scoreGate = gate
        writeSummary(RunSummary(of: outcome, ended: .finished, report: didSave ? reportPath : nil, gate: gate))

        if let oneMutantRun {
            logger.oneMutantTested(oneMutantRun, reportPath: reportPath.isEmpty ? nil : (reportPath, didSave))
            resultsFilePath.map(logger.resultsFileKept(atPath:))
            gate.map(logger.scoreGateChecked)
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
            unprovenKillWarning: outcome.unprovenKillWarning
        )
        resultsFilePath.map(logger.resultsFileKept(atPath:))
        gate.map(logger.scoreGateChecked)
    }

    /// Writes what was tested to a partial report beside the requested one, never replacing it, and says what was
    /// tested, and the command that continues the run: SwiftMutator's own arguments, resuming from the results file.
    /// Without a requested report there is no partial one: the summary and the results file say what was tested, and a
    /// report printed to the terminal would run to thousands of lines. A run of one mutant (`--mutant`) can't be
    /// resumed, and gets no such command: the same command tests it again. With a `failUnder`, the summary records that
    /// it wasn't checked, and nothing is said of it: the run's end says why it stopped, and it exits for that.
    private func mutationTestingEndedEarly(_ earlyEnd: EarlyEnd) {
        var partialReport: (path: String, saved: Bool)?
        if !earlyEnd.outcome.mutations.isEmpty,
           let path = PartialReport.path(besides: runOptions.reportOptions.path) {
            let report = runOptions.reportOptions.reporter.report(from: earlyEnd.outcome)
            partialReport = (path, ReportWriter.save(report, to: path, using: fileManager))
        }
        writeSummary(RunSummary(
            of: earlyEnd.outcome,
            ended: earlyEnd.reason,
            endDetail: earlyEnd.detail,
            report: partialReport.flatMap { $0.saved ? $0.path : nil },
            gate: earlyEnd.outcome.failUnder.map {
                ScoreGate(failUnder: $0, judging: earlyEnd.outcome, unless: .endedEarly)
            }
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
            partialReport: partialReport,
            resultsFile: resultsFilePath,
            continueCommand: continueCommand
        )
    }
}
