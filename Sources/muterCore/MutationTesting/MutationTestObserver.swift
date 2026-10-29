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
    private var flushStdOut: () -> Void
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.commandLineArguments)
    private var commandLineArguments: [String]

    private(set) var loggingDirectory: String = ""
    /// The run's results file, while every result has been written to it.
    private var resultsFilePath: String?
    private let runOptions: Run.Options

    /// The observer's registration with the run's events, from `start()`; it ends when the observer does.
    private var subscription: RunEvents.Subscription?

    init(runOptions: Run.Options) {
        self.runOptions = runOptions
    }

    /// Creates the run's log folder, and observes the run's events.
    func start() {
        loggingDirectory = createLoggingDirectory(
            forProjectAt: fileManager.currentDirectoryPath,
            fileManager: fileManager
        )

        subscription = events.observe { [weak self] event in self?.handle(event) }
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

        case let .resumePlanned(summary):
            logger.resumePlanned(summary)
        case .mutationTestingStarted:
            logger.mutationTestingStarted()
        case .mutantRunsStarted:
            logger.mutantRunsStarted()
        case let .stopAtFirstFailureTurnedOff(reason):
            logger.stopAtFirstFailureTurnedOff(reason: reason)
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

        case let .configurationFileCreated(path):
            logger.configurationFileCreated(atPath: path)

        case let .testPlanFileCreated(path):
            logger.testPlanFileCreated(atPath: path)

        case .muterMutationTestPlanLoaded:
            logger.muterMutationTestPlanLoaded()
        }
    }

    private func writeTestLog(_ mutationTestLog: MutationTestLog) {
        _ = fileManager.createFile(
            atPath: "\(loggingDirectory)/\(mutationTestLog.keptFileName)",
            contents: mutationTestLog.testLog.data(using: .utf8),
            attributes: nil
        )
    }

    private func mutationTestingFinished(_ outcome: MutationTestOutcome) {
        let reporter = runOptions.reportOptions.reporter
        let reportPath = runOptions.reportOptions.path ?? ""
        let report = reporter.report(from: outcome)
        let didSave = ReportWriter.save(report, to: reportPath, using: fileManager)

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
    /// report printed to the terminal would run to thousands of lines.
    private func mutationTestingEndedEarly(_ earlyEnd: EarlyEnd) {
        var partialReport: (path: String, saved: Bool)?
        if !earlyEnd.outcome.mutations.isEmpty,
           let path = PartialReport.path(besides: runOptions.reportOptions.path) {
            let report = runOptions.reportOptions.reporter.report(from: earlyEnd.outcome)
            partialReport = (path, ReportWriter.save(report, to: path, using: fileManager))
        }
        // A run from a test plan can't be resumed: ResumeCheck refuses it.
        let continueCommand = runOptions.isUsingTestPlan
            ? nil
            : resultsFilePath.map { ResumeHint.command(continuing: commandLineArguments, from: $0) }
        logger.mutationTestingEndedEarly(
            earlyEnd,
            partialReport: partialReport,
            resultsFile: resultsFilePath,
            continueCommand: continueCommand
        )
    }
}
