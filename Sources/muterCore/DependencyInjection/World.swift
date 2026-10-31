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
typealias LoadSourceCode = @Sendable (String) -> SourceCodeInfo?
typealias ProjectCoverage = @Sendable (BuildSystem) -> BuildSystemCoverage?
typealias Now = @Sendable () -> Date
typealias Instant = @Sendable () -> DispatchTime
typealias TestingTimeoutExecutorFactory = @Sendable () -> TestingTimeoutExecution
typealias ProvenanceProbe = @Sendable (MuterConfiguration) async -> Provenance
/// The files in a project, relative to it, or nil if it can't list them.
typealias ProjectFileListing = @Sendable (URL) async -> [String]?
/// Waits that many nanoseconds, or throws a CancellationError once the task is cancelled.
typealias Sleep = @Sendable (UInt64) async throws -> Void

struct World: Sendable {
    /// What happens during the run, for its observer to report.
    var events = RunEvents()
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

    var ioDelegate: MutationTestingIODelegate = MutationTestingDelegate()
    var process: ProcessFactory = { MuterProcessFactory.makeProcess() }
    var prepareCode: SourceCodePreparation = { PrepareSourceCode().prepareSourceCode($0) }
    var writeFile: WriteFile = { try $0.write(toFile: $1, atomically: true, encoding: .utf8) }
    var loadSourceCode: LoadSourceCode = { sourceCode(fromFileAt: $0) }
    var projectCoverage: ProjectCoverage = { BuildSystem.coverage(for: $0) }
    var server: Server = URLSession.shared
    var now: Now = { Date() }
    /// The monotonic clock, which stands still while SwiftMutator is suspended (`suspensions`).
    var instant: Instant = { current.suspensions.instant }
    var testingTimeOutExecutor: TestingTimeoutExecutorFactory = { TestingTimeoutExecutor() }
    var provenance: ProvenanceProbe = { await Provenance.probe($0) }
    var resultsFiles: ResultsFileOpening = ResultsFile.Opener()
    var mutatedProjectLocker: MutatedProjectLocking = MutatedProjectLock.Locker()
    var listProjectFiles: ProjectFileListing = { await GitFileListing.list(in: $0) }
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
