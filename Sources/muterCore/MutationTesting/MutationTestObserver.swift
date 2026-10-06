#if os(Linux)
import Glibc
#else
import Darwin.C
#endif
import Foundation
import Rainbow
import SwiftSyntax

extension Notification.Name {
    static let muterLaunched = Notification.Name("muterLaunched")

    static let updateCheckStarted = Notification.Name("updateCheckStarted")
    static let updateCheckFinished = Notification.Name("updateCheckFinished")

    static let projectCopyStarted = Notification.Name("projectCopyStarted")
    static let projectCopyFinished = Notification.Name("projectCopyFinished")
    static let projectCopySkippedVanishedFiles = Notification.Name("projectCopySkippedVanishedFiles")

    static let projectCoverageDiscoveryStarted = Notification.Name("projectCoverageDiscoveryStarted")
    static let projectCoverageDiscoveryFinished = Notification.Name("projectCoverageDiscoveryFinished")

    static let sourceFileDiscoveryStarted = Notification.Name("sourceFileDiscoveryStarted")
    static let sourceFileDiscoveryFinished = Notification.Name("sourceFileDiscoveryFinished")

    static let mutationsDiscoveryStarted = Notification.Name("mutationsDiscoveryStarted")
    static let mutationsDiscoveryFinished = Notification.Name("mutationsDiscoveryFinished")

    /// The object is a `ResumeSummary`: what a resumed run keeps of its results file and tests again, before anything
    /// is tested.
    static let resumePlanned = Notification.Name("resumePlanned")
    static let mutationTestingStarted = Notification.Name("mutationTestingStarted")
    static let stopAtFirstFailureTurnedOff = Notification.Name("stopAtFirstFailureTurnedOff")
    static let mutationTestingFinished = Notification.Name("mutationTestingFinished")
    /// The object is an `EarlyEnd`: what mutation testing tested before it stopped early, once the baseline passed.
    static let mutationTestingEndedEarly = Notification.Name("mutationTestingEndedEarly")

    static let newMutationTestOutcomeAvailable = Notification.Name("newMutationTestOutcomeAvailable")
    static let newTestLogAvailable = Notification.Name("newTestLogAvailable")
    static let baselineTestFailed = Notification.Name("baselineTestFailed")
    /// The object is the results file's path.
    static let resultsFileCreated = Notification.Name("resultsFileCreated")
    /// The object is why the results file can't be created or written to.
    static let resultsFileUnavailable = Notification.Name("resultsFileUnavailable")

    static let configurationFileCreated = Notification.Name("configurationFileCreated")

    static let testPlanFileCreated = Notification.Name("testPlanFileCreated")

    static let muterMutationTestPlanLoaded = Notification.Name("muterMutationTestPlanLoaded")
}

final class MutationTestObserver {
    @Dependency(\.logger)
    private var logger: Logger
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager
    @Dependency(\.flushStandardOut)
    private var flushStdOut: () -> Void
    @Dependency(\.notificationCenter)
    private var notificationCenter: NotificationCenter

    private var numberOfMutationPoints: Int = 0
    private(set) var loggingDirectory: String = ""
    /// The run's results file, while every result has been written to it.
    private var resultsFilePath: String?
    private let runOptions: Run.Options

    private var notificationHandlerMappings: [(name: Notification.Name, handler: (Notification) -> Void)] {
        [
            (name: .muterLaunched, handler: handleMuterLaunched),

            (name: .updateCheckStarted, handler: handleUpdateCheckStarted),
            (name: .updateCheckFinished, handler: handleUpdateCheckFinished),

            (name: .projectCopyStarted, handler: handleProjectCopyStarted),
            (name: .projectCopySkippedVanishedFiles, handler: handleProjectCopySkippedVanishedFiles),
            (name: .projectCopyFinished, handler: handleProjectCopyFinished),

            (name: .projectCoverageDiscoveryStarted, handler: handleProjectCoverageDiscoveryStarted),
            (name: .projectCoverageDiscoveryFinished, handler: handleProjectCoverageDiscoveryFinished),

            (name: .sourceFileDiscoveryStarted, handler: handleSourceFileDiscoveryStarted),
            (name: .sourceFileDiscoveryFinished, handler: handleSourceFileDiscoveryFinished),

            (name: .mutationsDiscoveryStarted, handler: handleMutationsDiscoveryStarted),
            (name: .mutationsDiscoveryFinished, handler: handleMutationsDiscoveryFinished),

            (name: .resumePlanned, handler: handleResumePlanned),
            (name: .mutationTestingStarted, handler: handleMutationTestingStarted),
            (name: .stopAtFirstFailureTurnedOff, handler: handleStopAtFirstFailureTurnedOff),

            (name: .newMutationTestOutcomeAvailable, handler: handleNewMutationTestOutcomeAvailable),
            (name: .newTestLogAvailable, handler: handleNewTestLogAvailable),
            (name: .baselineTestFailed, handler: handleBaselineTestFailed),
            (name: .resultsFileCreated, handler: handleResultsFileCreated),
            (name: .resultsFileUnavailable, handler: handleResultsFileUnavailable),

            (name: .mutationTestingFinished, handler: handleMutationTestingFinished),
            (name: .mutationTestingEndedEarly, handler: handleMutationTestingEndedEarly),

            (name: .configurationFileCreated, handler: handleConfigurationFileCreated),

            (name: .testPlanFileCreated, handler: handleTestPlanFileCreated),

            (name: .muterMutationTestPlanLoaded, handler: handleMuterMutationTestPlanLoaded),
        ]
    }

    init(runOptions: Run.Options) {
        self.runOptions = runOptions
    }

    func start() {
        loggingDirectory = createLoggingDirectory(
            forProjectAt: fileManager.currentDirectoryPath,
            fileManager: fileManager
        )

        for (name, handler) in notificationHandlerMappings {
            _ = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil,
                using: handler
            )
        }
    }

    deinit {
        notificationCenter.removeObserver(self)
    }
}

extension MutationTestObserver {
    func handleMuterLaunched(notification: Notification) {
        logger.launched()
    }

    func handleUpdateCheckStarted(notification: Notification) {
        logger.updateCheckStarted()
    }

    func handleUpdateCheckFinished(notification: Notification) {
        logger.updateCheckFinished(newVersion: notification.object as? String)
    }

    func handleProjectCopyStarted(notification: Notification) {
        logger.projectCopyStarted()
    }

    func handleProjectCopySkippedVanishedFiles(notification: Notification) {
        (notification.object as? [String]).map(logger.projectCopySkippedVanishedFiles)
    }

    func handleProjectCopyFinished(notification: Notification) {
        logger.projectCopyFinished(destinationPath: notification.object as! String)
    }

    func handleProjectCoverageDiscoveryStarted(notification: Notification) {
        logger.projectCoverageDiscoveryStarted()
    }

    func handleProjectCoverageDiscoveryFinished(notification: Notification) {
        (notification.object as? Bool).map {
            logger.projectCoverageDiscoveryFinished(success: $0)
        }
    }

    func handleSourceFileDiscoveryStarted(notification: Notification) {
        logger.sourceFileDiscoveryStarted()
    }

    func handleSourceFileDiscoveryFinished(notification: Notification) {
        logger.sourceFileDiscoveryFinished(sourceFileCandidates: notification.object as! [String])
    }

    func handleMutationsDiscoveryStarted(notification: Notification) {
        logger.mutationsDiscoveryStarted()
    }

    func handleMutationsDiscoveryFinished(notification: Notification) {
        logger.mutationsDiscoveryFinished(mutations: notification.object as! [SchemataMutationMapping])
    }

    func handleResumePlanned(notification: Notification) {
        (notification.object as? ResumeSummary).map(logger.resumePlanned)
    }

    func handleMutationTestingStarted(notification: Notification) {
        logger.mutationTestingStarted()
    }

    func handleStopAtFirstFailureTurnedOff(notification: Notification) {
        (notification.object as? String).map(logger.stopAtFirstFailureTurnedOff(reason:))
    }

    func handleNewMutationTestOutcomeAvailable(notification: Notification) {
        runOptions.reportOptions.reporter.newMutationTestOutcomeAvailable(
            outcomeWithFlush: MutationOutcomeWithFlush(
                mutation: notification.object as! MutationTestOutcome.Mutation,
                fflush: flushStdOut
            )
        )
    }

    func handleNewTestLogAvailable(notification: Notification) {
        let mutationTestLog = notification.object as! MutationTestLog

        logger.newMutationTestLogAvailable(mutationTestLog: mutationTestLog)

        writeTestLog(mutationTestLog)
    }

    /// Records the log only. The abort message reports the failure to the console, and there is no
    /// progress left to announce.
    func handleBaselineTestFailed(notification: Notification) {
        writeTestLog(notification.object as! MutationTestLog)
    }

    private func writeTestLog(_ mutationTestLog: MutationTestLog) {
        _ = fileManager.createFile(
            atPath: "\(loggingDirectory)/\(logFileName(from: mutationTestLog.mutationPoint))",
            contents: mutationTestLog.testLog.data(using: .utf8),
            attributes: nil
        )
    }

    func logFileName(from mutationPoint: MutationPoint?) -> String {
        MutationTestLog.keptFileName(for: mutationPoint)
    }

    func handleResultsFileCreated(notification: Notification) {
        guard let path = notification.object as? String else { return }
        resultsFilePath = path
        logger.resultsFileCreated(atPath: path)
    }

    /// The file, if there is one, lacks every result after the failed write, so the end of the run doesn't name it.
    func handleResultsFileUnavailable(notification: Notification) {
        resultsFilePath = nil
        (notification.object as? String).map(logger.resultsFileUnavailable(reason:))
    }

    func handleMutationTestingFinished(notification: Notification) {
        let reporter = runOptions.reportOptions.reporter
        let reportPath = runOptions.reportOptions.path ?? ""
        let report = reporter.report(from: notification.object as! MutationTestOutcome)
        let didSave = ReportWriter.save(report, to: reportPath, using: fileManager)

        logger.mutationTestingFinished(
            report: report,
            reportPath: reportPath,
            isExportingReport: !reportPath.isEmpty,
            didSaveReport: didSave
        )
        resultsFilePath.map(logger.resultsFileKept(atPath:))
    }

    /// Writes what was tested to a partial report beside the requested one, never replacing it, and says what was
    /// tested. Without a requested report there is no partial one: the summary and the results file say what was
    /// tested, and a report printed to the terminal would run to thousands of lines.
    func handleMutationTestingEndedEarly(notification: Notification) {
        guard let earlyEnd = notification.object as? EarlyEnd else { return }
        var partialReport: (path: String, saved: Bool)?
        if !earlyEnd.outcome.mutations.isEmpty,
           let path = PartialReport.path(besides: runOptions.reportOptions.path) {
            let report = runOptions.reportOptions.reporter.report(from: earlyEnd.outcome)
            partialReport = (path, ReportWriter.save(report, to: path, using: fileManager))
        }
        logger.mutationTestingEndedEarly(earlyEnd, partialReport: partialReport, resultsFile: resultsFilePath)
    }

    func handleTestPlanFileCreated(notification: Notification) {
        logger.testPlanFileCreated(atPath: notification.object as? String)
    }

    func handleConfigurationFileCreated(notification: Notification) {
        logger.configurationFileCreated(atPath: notification.object as? String)
    }

    func handleMuterMutationTestPlanLoaded(notification: Notification) {
        logger.muterMutationTestPlanLoaded()
    }
}
