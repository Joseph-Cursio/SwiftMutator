#if os(Linux)
import FoundationNetworking
// Glibc declares `stdout` and `stderr` as mutable globals, which Swift 6 won't let a `@Sendable` closure read unless
// the import is `@preconcurrency`. Neither is reassigned once the process is running.
@preconcurrency import Glibc
#endif
import Foundation

/// SwiftMutator's dependencies. Steps, signal handlers, time limits and GCD queues read them from any thread, so they
/// are behind a lock. Only tests replace them, so only a debug build can.
#if DEBUG
var current: World {
    get { worldBox.world }
    set { worldBox.world = newValue }
}
#else
var current: World { worldBox.world }
#endif

private let worldBox = WorldBox()

private final class WorldBox: @unchecked Sendable { // `stored` is behind `lock`
    private let lock = NSLock()
    private var stored = World()

    var world: World {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// One dependency, without copying the whole world.
    func read<T>(_ keyPath: KeyPath<World, T>) -> T {
        lock.withLock { stored[keyPath: keyPath] }
    }
}

/// `current[keyPath: keyPath]`, read under the world's lock.
func dependency<T>(_ keyPath: KeyPath<World, T>) -> T {
    worldBox.read(keyPath)
}

typealias PreparedSourceCode = (
    source: SourceCodeInfo,
    changes: MutationSourceCodePreparationChange
)
typealias SourceCodePreparation = @Sendable (String) -> PreparedSourceCode?
typealias ProcessFactory = @Sendable () -> Process
typealias Flush = @Sendable () -> Void
typealias Printer = @Sendable (String) -> Void
typealias WriteFile = @Sendable (String, String) throws -> Void
/// Makes the folder at a path, which only its owner can use, and those it is in.
typealias MakeFolder = @Sendable (String) throws -> Void
typealias LoadSourceCode = @Sendable (String) -> SourceCodeInfo?
/// A file's bytes, by its absolute path, or nil if it can't be read.
typealias ReadFile = @Sendable (String) -> Data?
/// Where a project is in the git work tree it's in, by the project's recorded absolute path (`WorkTree.place(of:)`),
/// or nil if it isn't in one.
typealias ProjectInWorkTree = @Sendable (String) -> WorkTree.Place?
typealias ProjectCoverage = @Sendable (BuildSystem) -> BuildSystemCoverage?
typealias Now = @Sendable () -> Date
typealias Instant = @Sendable () -> DispatchTime
typealias TestingTimeoutExecutorFactory = @Sendable () -> TestingTimeoutExecution
typealias ProvenanceProbe = @Sendable (MuterConfiguration) async -> Provenance
/// How a project's test bundles can be run without `swift test`, or why they can't.
typealias DirectTestRunProbe = @Sendable (MuterConfiguration, _ project: URL) async
    -> Result<DirectTestRun, DirectTestRun.Unavailable>
/// The files in a project, relative to it, or nil if it can't list them.
typealias ProjectFileListing = @Sendable (URL) async -> [String]?
/// `--since`'s choice: the ref, whether only changed lines count, and the project.
typealias ChangeSelectionProbe = @Sendable (String, Bool, URL) async -> Result<ChangeSelection, ChangeSelectionError>
/// Waits that many nanoseconds, or throws a CancellationError once the task is cancelled.
typealias Sleep = @Sendable (UInt64) async throws -> Void

struct World: Sendable {
    /// What happens during the run, for its observer to report.
    var events = RunEvents()
    #if os(Linux)
    /// One of its own: FoundationEssentials traps when the shared FileManager is given a delegate, as the project
    /// copy gives this one.
    var fileManager: FileSystemManager = FileManager()
    #else
    var fileManager: FileSystemManager = FileManager.default
    #endif
    var flushStandardOut: Flush = { fflush(stdout) }
    var logger: Logger = .init()
    var printer: Printer = { print($0) }
    /// Standard error, written with `fputs`: `FileHandle.write(_:)` raises an exception once the terminal has hung up
    /// or the reader has gone.
    var errorPrinter: Printer = { fputs($0 + "\n", stderr) }
    /// Whether standard output is a terminal, where the progress bar can redraw itself. A log file or a pipe gets a
    /// line per mutant instead.
    var standardOutIsATerminal = Self.isTerminal(
        isatty: isatty(STDOUT_FILENO) != 0,
        term: ProcessInfo.processInfo.environment["TERM"]
    )

    var ioDelegate: MutationTestingIODelegate = MutationTestingDelegate()
    var process: ProcessFactory = { MuterProcessFactory.makeProcess() }
    var prepareCode: SourceCodePreparation = { PrepareSourceCode().prepareSourceCode($0) }
    /// The same, without writing the file back: for a file coverage leaves out, whose mutants are counted, not made.
    var readPreparedCode: SourceCodePreparation = { PrepareSourceCode().prepareSourceCode($0, writing: false) }
    var writeFile: WriteFile = { try $0.write(toFile: $1, atomically: true, encoding: .utf8) }
    var makeFolder: MakeFolder = {
        try FileManager.default.createDirectory(
            atPath: $0, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
    var loadSourceCode: LoadSourceCode = { sourceCode(fromFileAt: $0) }
    /// The original files the reports show each mutant's line from.
    var readSourceFile: ReadFile = { FileManager.default.contents(atPath: $0) }
    /// The work tree the SARIF report's paths are from.
    var projectInWorkTree: ProjectInWorkTree = { WorkTree.place(of: $0) }
    var projectCoverage: ProjectCoverage = { BuildSystem.coverage(for: $0) }
    var server: Server = URLSession.shared
    var now: Now = { Date() }
    /// The monotonic clock, which stands still while SwiftMutator is suspended (`suspensions`).
    var instant: Instant = { current.suspensions.instant }
    var testingTimeOutExecutor: TestingTimeoutExecutorFactory = { TestingTimeoutExecutor() }
    var provenance: ProvenanceProbe = { await Provenance.probe($0) }
    var directTestRun: DirectTestRunProbe = { await DirectTestRun.probe($0, in: $1) }
    var resultsFiles: ResultsFileOpening = ResultsFile.Opener()
    var mutatedProjectLocker: MutatedProjectLocking = MutatedProjectLock.Locker()
    /// The simulators an xcodebuild run's workers test on, and those earlier runs left behind.
    var workerSimulators: WorkerSimulating = WorkerSimulators()
    var listProjectFiles: ProjectFileListing = { await GitFileListing.list(in: $0) }
    var selectChanges: ChangeSelectionProbe = { await GitChanges.select(since: $0, changedLines: $1, in: $2) }
    /// SwiftMutator's command-line arguments, after the executable: what a results file's header records, and what the
    /// command that continues a stopped run repeats.
    var commandLineArguments: [String] = Array(CommandLine.arguments.dropFirst())
    /// The signal that stopped this run, if one did.
    var interruption = InterruptionRecord()
    /// Records a run that stops before its first mutant, following its steps until its results start.
    var stoppedRun = StoppedRunRecorder()
    /// The time SwiftMutator spent suspended by Ctrl-Z, which no time limit counts.
    var suspensions = Suspensions()
    /// A wait on the system's uptime clock, which counts the time suspended, unlike `suspensions.sleep(for:)`.
    var sleep: Sleep = { try await Task.sleep(nanoseconds: $0) }
    /// A project's files, to see whether a run of its tests wrote any.
    var projectFiles: @Sendable (URL) -> ProjectFiles? = { ProjectFiles.read(in: $0) }
    /// How many processors can run at once, which a SwiftPM run's default worker count goes by.
    var processorCount = ProcessInfo.processInfo.activeProcessorCount
}

extension World {
    /// Rainbow's test of where it can colour: standard output is a tty, and TERM is set and isn't "dumb". So the
    /// progress bar redraws itself wherever colour could show. NO_COLOR turns off the colour, not the bar.
    static func isTerminal(isatty: Bool, term: String?) -> Bool {
        guard isatty, let term else { return false }
        return term.lowercased() != "dumb"
    }
}
