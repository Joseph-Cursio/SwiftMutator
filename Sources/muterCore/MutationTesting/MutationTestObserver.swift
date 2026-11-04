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
    @Dependency(\.flushStandardOut)
    private var flushStdOut: Flush
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.commandLineArguments)
    private var commandLineArguments: [String]

    private(set) var loggingDirectory: String = ""
    /// The run's results file, while every result has been written to it.
    private var resultsFilePath: String?
    /// The merge base `--since` compared the working tree with, which the command that continues the run names.
    private var sinceMergeBase: String?
    /// The run of the one mutant `--mutant` tests, which the end of the run prints in place of the report.
    private var oneMutantRun: OneMutantRun?
    private let runOptions: Run.Options

    /// The observer's registration with the run's events, from `start()`; it ends when the observer does.
    private var subscription: RunEvents.Subscription?

    init(runOptions: Run.Options) {
        self.runOptions = runOptions
    }

    /// Creates the run's log folder, and observes the run's events.
    func start() throws {
        loggingDirectory = try createLoggingDirectory(
            forProjectAt: fileManager.currentDirectoryPath,
            fileManager: fileManager
        )

        subscription = events.observe { [weak self] event in self?.handle(event) }
    }

    /// Removes the run's log folder if the run kept nothing in it. That happens when a run is refused or fails before
    /// its first log. A resumed session that runs no coverage and has nothing left to test keeps its folder, which
    /// holds its note naming the results file (`ResultsFile.noteFileName`). The logs' root, `<project>_muter_logs`,
    /// stays, because another run of the project may be claiming a folder in it at the same moment. Before `start()`
    /// there is no folder, and nothing is removed.
    func removeLoggingDirectoryIfEmpty() {
        guard !loggingDirectory.isEmpty else { return }
        removeFolderIfEmpty(atPath: loggingDirectory, fileManager: fileManager)
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

        case .sourceFileDiscoveryStarted:
            logger.sourceFileDiscoveryStarted()
        case let .packageSourceFilesUnavailable(reason):
            logger.packageSourceFilesUnavailable(reason: reason)
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
        case let .controlRunFinished(control):
            logger.controlRunFinished(control)
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
            writeTestLog(rerun.log)
            logger.timeoutRerunFinished(rerun)
        case let .timeoutRerunsFinished(tally):
            logger.timeoutRerunsFinished(tally)
        case let .runRepeatedAfterLaunchFailure(repeated):
            writeTestLog(repeated.log)
            logger.runRepeatedAfterLaunchFailure(repeated)
        case let .baselineRepeatedAfterLaunchFailure(line, log):
            writeTestLog(log)
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
            writeTestLog(mutationTestLog)
        case let .baselineTestFailed(mutationTestLog):
            // Records the log only. The abort message reports the failure to the console, and there is no progress
            // left to announce.
            writeTestLog(mutationTestLog)
        case let .resultsFileCreated(path):
            resultsFilePath = path
            logger.resultsFileCreated(atPath: path)
        case let .resultsFileUnavailable(reason):
            // The file, if there is one, lacks every result after the failed write, so the end of the run doesn't name
            // it.
            resultsFilePath = nil
            logger.resultsFileUnavailable(reason: reason)

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
        }
    }

    private func writeTestLog(_ mutationTestLog: MutationTestLog) {
        _ = fileManager.createFile(
            atPath: "\(loggingDirectory)/\(mutationTestLog.keptFileName)",
            contents: mutationTestLog.testLog.data(using: .utf8),
            attributes: nil
        )
    }

    /// Says the run finished, then prints its report, or where it went, or for a run of one mutant (`--mutant`) what
    /// it changes, its tests' log and its verdict, and where a requested report went; then where each result is.
    private func mutationTestingFinished(_ outcome: MutationTestOutcome) {
        let reporter = runOptions.reportOptions.reporter
        let reportPath = runOptions.reportOptions.path ?? ""
        let report = reporter.report(from: outcome)
        let didSave = ReportWriter.save(report, to: reportPath, using: fileManager)

        if let oneMutantRun {
            logger.oneMutantTested(oneMutantRun, reportPath: reportPath.isEmpty ? nil : (reportPath, didSave))
            resultsFilePath.map(logger.resultsFileKept(atPath:))
            return
        }
        logger.mutationTestingFinished(
            report: report,
            reportPath: reportPath,
            isExportingReport: !reportPath.isEmpty,
            didSaveReport: didSave,
            suspectWarning: KillingTestSummary.warning(for: outcome)
        )
        resultsFilePath.map(logger.resultsFileKept(atPath:))
    }

    /// Writes what was tested to a partial report beside the requested one, never replacing it, and says what was
    /// tested, and the command that continues the run: SwiftMutator's own arguments, resuming from the results file.
    /// Without a requested report there is no partial one: the summary and the results file say what was tested, and a
    /// report printed to the terminal would run to thousands of lines. A run of one mutant (`--mutant`) can't be
    /// resumed, and gets no such command: the same command tests it again.
    private func mutationTestingEndedEarly(_ earlyEnd: EarlyEnd) {
        var partialReport: (path: String, saved: Bool)?
        if !earlyEnd.outcome.mutations.isEmpty,
           let path = PartialReport.path(besides: runOptions.reportOptions.path) {
            let report = runOptions.reportOptions.reporter.report(from: earlyEnd.outcome)
            partialReport = (path, ReportWriter.save(report, to: path, using: fileManager))
        }
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
