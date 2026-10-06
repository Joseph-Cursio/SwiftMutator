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
typealias ProvenanceProbe = (MuterConfiguration) -> Provenance
/// The files in a project, relative to it, or nil if it can't list them.
typealias ProjectFileListing = (URL) -> [String]?

struct World {
    var notificationCenter: NotificationCenter = .default
    var fileManager: FileSystemManager = FileManager.default
    var flushStandardOut: Flush = { fflush(stdout) }
    var logger: Logger = .init()
    var printer: Printer = { print($0) }
    /// Standard error, written with `fputs`: `FileHandle.write(_:)` raises an exception once the terminal has hung up
    /// or the reader has gone.
    var errorPrinter: Printer = { fputs($0 + "\n", stderr) }
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
    var instant: Instant = DispatchTime.now
    var testingTimeOutExecutor: TestingTimeoutExecutorFactory = { TestingTimeoutExecutor() }
    var provenance: ProvenanceProbe = { Provenance.probe($0) }
    var resultsFiles: ResultsFileOpening = ResultsFile.Opener()
    var listProjectFiles: ProjectFileListing = GitFileListing.list(in:)
    /// The signal that stopped this run, if one did.
    var interruption = InterruptionRecord()
}
