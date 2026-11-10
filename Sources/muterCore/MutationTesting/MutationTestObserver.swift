#if os(Linux)
import Glibc
#else
import Darwin.C
#endif

final class MutationTestObserver {
    @Dependency(\.logger)
    var logger: Logger
    @Dependency(\.fileManager)
    var fileManager: FileSystemManager
    @Dependency(\.writeFile)
    var writeFile: WriteFile
    @Dependency(\.flushStandardOut)
    var flushStdOut: Flush
    @Dependency(\.events)
    private var events: RunEvents
    @Dependency(\.commandLineArguments)
    var commandLineArguments: [String]

    private(set) var loggingDirectory: String = ""
    /// The run's marker in its log folder, locked from `start()` until the observer goes, so no other run prunes the
    /// folder meanwhile (`RunMarker`); nil when it couldn't be made.
    private var runMarker: RunMarker?
    /// The run's results file, while every result has been written to it.
    var resultsFilePath: String?
    /// The merge base `--since` compared the working tree with, which the command that continues the run names.
    var sinceMergeBase: String?
    /// The run of the one mutant `--mutant` tests, which the end of the run prints in place of the report.
    var oneMutantRun: OneMutantRun?
    /// The finished run's verdicts, which the run exits with: on its score against its `failUnder`, on its survivors
    /// and its score against `--baseline`'s file, and on its doubtful kills. Each nil without its flag, and all for a
    /// run that didn't finish.
    var checks = RunChecks()
    /// The finished run's verdict on its score against its `failUnder`; nil without one, and for a run that didn't
    /// finish.
    var scoreGate: ScoreGate? {
        checks.scoreGate
    }
    let runOptions: Run.Options

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
        if removeFolderIfEmpty(atPath: loggingDirectory, fileManager: fileManager, ignoring: [RunMarker.fileName]) {
            runMarker?.release()
        }
    }
}
