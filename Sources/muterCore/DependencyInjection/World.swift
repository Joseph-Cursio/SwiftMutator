#if os(Linux)
import FoundationNetworking
#endif
import Foundation

#if DEBUG
var current = World()
#else
let current = World()
#endif

typealias ProgressBarInitializer = (
    Int,
    [ProgressElementType]?,
    ProgressBarPrinter?
) -> ProgressBar

typealias PreparedSourceCode = (
    source: SourceCodeInfo,
    changes: MutationSourceCodePreparationChange
)
typealias SourceCodePreparation = (String) -> PreparedSourceCode?
typealias ProcessFactory = () -> Process
typealias Flush = () -> Void
typealias Printer = (String) -> Void
typealias WriteFile = (String, String) throws -> Void
typealias LoadSourceCode = (String) -> SourceCodeInfo?
typealias ProjectCoverage = (BuildSystem) -> BuildSystemCoverage?
typealias Now = () -> Date
typealias Instant = () -> DispatchTime
typealias TestingTimeoutExecutorFactory = () -> TestingTimeoutExecution
typealias ProvenanceProbe = (MuterConfiguration) async -> Provenance
/// The files in a project, relative to it, or nil if it can't list them.
typealias ProjectFileListing = (URL) async -> [String]?
/// Waits that many nanoseconds, or throws a CancellationError once the task is cancelled.
typealias Sleep = (UInt64) async throws -> Void

struct World {
    var notificationCenter: NotificationCenter = .default
    var fileManager: FileSystemManager = FileManager.default
    var flushStandardOut: Flush = { fflush(stdout) }
    var logger: Logger = .init()
    var printer: Printer = { print($0) }
    /// Standard error, written with `fputs`: `FileHandle.write(_:)` raises an exception once the terminal has hung up
    /// or the reader has gone.
    var errorPrinter: Printer = { fputs($0 + "\n", stderr) }
    /// Whether standard output is a terminal, where the progress bar can redraw itself. A log file or a pipe gets a
    /// line per mutant instead.
    var standardOutIsATerminal = World.isTerminal(
        isatty: isatty(STDOUT_FILENO) != 0,
        term: ProcessInfo.processInfo.environment["TERM"]
    )
    var progressBar: ProgressBarInitializer = {
        ProgressBar(
            count: $0,
            configuration: $1,
            printer: $2
        )
    }

    var ioDelegate: MutationTestingIODelegate = MutationTestingDelegate()
    var process: ProcessFactory = MuterProcessFactory.makeProcess
    var prepareCode: SourceCodePreparation = PrepareSourceCode().prepareSourceCode
    var writeFile: WriteFile = { try $0.write(toFile: $1, atomically: true, encoding: .utf8) }
    var loadSourceCode: LoadSourceCode = { sourceCode(fromFileAt: $0) }
    var projectCoverage: ProjectCoverage = BuildSystem.coverage
    var server: Server = URLSession.shared
    var now: Now = Date.init
    /// The monotonic clock, which stands still while SwiftMutator is suspended (`suspensions`).
    var instant: Instant = { current.suspensions.instant }
    var testingTimeOutExecutor: TestingTimeoutExecutorFactory = { TestingTimeoutExecutor() }
    var provenance: ProvenanceProbe = { await Provenance.probe($0) }
    var resultsFiles: ResultsFileOpening = ResultsFile.Opener()
    var mutatedProjectLocker: MutatedProjectLocking = MutatedProjectLock.Locker()
    var listProjectFiles: ProjectFileListing = GitFileListing.list(in:)
    /// SwiftMutator's command-line arguments, after the executable: what a results file's header records, and what the
    /// command that continues a stopped run repeats.
    var commandLineArguments: [String] = Array(CommandLine.arguments.dropFirst())
    /// The signal that stopped this run, if one did.
    var interruption = InterruptionRecord()
    /// The time SwiftMutator spent suspended by Ctrl-Z, which no time limit counts.
    var suspensions = Suspensions()
    /// A wait on the system's uptime clock, which counts the time suspended, unlike `suspensions.sleep(for:)`.
    var sleep: Sleep = { try await Task.sleep(nanoseconds: $0) }
}

extension World {
    /// Rainbow's test of where it can colour: standard output is a tty, and TERM is set and isn't "dumb". So the
    /// progress bar redraws itself wherever colour could show. NO_COLOR turns off the colour, not the bar.
    static func isTerminal(isatty: Bool, term: String?) -> Bool {
        guard isatty, let term else { return false }
        return term.lowercased() != "dumb"
    }
}
