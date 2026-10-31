import Foundation

enum BuildSystem: String, Codable, Equatable {
    case xcodebuild
    case swift
    case unknown

    init(rawValue: String) {
        switch rawValue {
        case "swift": self = .swift
        case "xcodebuild": self = .xcodebuild
        default: self = .unknown
        }
    }
}

extension BuildSystem {
    static func coverage(
        for buildSystem: BuildSystem
    ) -> BuildSystemCoverage? {
        switch buildSystem {
        case .swift: return SwiftCoverage()
        case .xcodebuild: return XcodeBuildCoverage()
        default: return nil
        }
    }
}

protocol BuildSystemCoverage: AnyObject {
    var process: ProcessFactory { get }
    /// What the coverage run printed, once `run` has run it, for the run's log folder; nil if it didn't run.
    var coverageRunOutput: String? { get }

    func run(
        with configuration: MuterConfiguration
    ) async -> Result<Coverage, CoverageError>

    func buildDirectory(_ configuration: MuterConfiguration) async -> String?
}

extension BuildSystemCoverage {
    /// The newest profile under any of `paths`. Xcode keeps one per run destination,
    /// `ProfileData/<device>/Coverage.profdata`, and leaves the other destinations' in place, as it does other build
    /// locations'. `find` lists them in no set order, and `llvm-cov` reads a stale one without failing: every function
    /// added since then counts as never run, so its mutants would be skipped.
    func testProfileData(at paths: [String]) async -> String? {
        var profiles: [String] = []
        for path in paths {
            profiles += (await process().find(atPath: path, byName: "*.profdata") ?? "")
                .components(separatedBy: "\n")
                .map(\.trimmed)
                .filter { !$0.isEmpty }
        }
        guard profiles.count > 1 else {
            return profiles.first
        }

        return await process().runProcess(url: "/bin/ls", arguments: ["-t"] + profiles)
            .flatMap { $0.components(separatedBy: "\n").first?.trimmed.nilIfEmpty }
    }

    /// llvm-cov's JSON export of `objects` with `profile`, from one call: the first object by name, then each other as
    /// an `-object`, so the code of every binary is read, as each test bundle maps only the code linked into it. An
    /// object with no coverage data, such as an app's stub executable, does no harm while another has some; one that
    /// doesn't exist fails the export. No file is left out: coverage is looked up only for the project's own files.
    /// `llvmCov` is how to run llvm-cov: the executable, and the arguments before llvm-cov's own. `architecture`, if
    /// given, is the one whose code llvm-cov reads in every object, which it needs for a universal binary.
    func llvmCovExport(
        of objects: [String],
        profile: String,
        llvmCov: (executable: String, arguments: [String]),
        architecture: String? = nil
    ) async -> Result<Data, CoverageError> {
        let objectArguments = Array(objects.prefix(1)) + objects.dropFirst().flatMap { ["-object", $0] }
        guard let export = await process().runCommand(
            url: llvmCov.executable,
            arguments: llvmCov.arguments + ["export"] + objectArguments + ["-instr-profile", profile]
                + (architecture.map { ["-arch", $0] } ?? [])
        ) else {
            return .failure(.couldNotRun("llvm-cov"))
        }
        guard export.succeeded else {
            // llvm-cov can warn first, as of an object newer than the profile.
            return .failure(.llvmCovFailed(Self.firstError(in: export.errors) ?? Self.firstLine(of: export.errors)))
        }

        return .success(Data(export.output.utf8))
    }

    /// The coverage of the project's own source files in `export`, llvm-cov's JSON: the share of their lines the tests
    /// ran, the files at or below `coverageThreshold` and every file the export names, by their path in the project,
    /// and the regions no test ran.
    /// The export also covers test files and dependencies, which don't count, and gives absolute paths. Nor do the
    /// files in `buildFolders` or `testFiles` count, as `ProjectSourceFiles` takes them.
    static func coverage(
        fromExport export: Data,
        projectRoot: String,
        coverageThreshold: Double,
        buildFolders: [FilePath] = [],
        testFiles: [FilePath] = [],
        testsFailedWithCoverageOn: FailedTestLine.FailedTests? = nil
    ) -> Result<Coverage, CoverageError> {
        guard let coverage = try? JSONDecoder().decode(LLVMCoverage.self, from: export),
              let report = coverage.data.first
        else {
            return .failure(.unreadableReport)
        }

        let projectFiles = ProjectSourceFiles(root: projectRoot, buildFolders: buildFolders, testFiles: testFiles)
        let files = report.files.compactMap { file -> (path: String, lines: LLVMCoverage.Lines)? in
            projectFiles.pathInProject(file.filename).map { ($0, file.summary.lines) }
        }
        guard !files.isEmpty else {
            return .failure(.noProjectFiles)
        }

        let lines = files.map(\.lines.count).reduce(0, +)
        let coveredLines = files.map(\.lines.covered).reduce(0, +)
        let filesWithoutCoverage = files
            .filter {
                ProjectSourceFiles.hasNoCoverage(
                    covered: $0.lines.covered,
                    of: $0.lines.count,
                    threshold: coverageThreshold
                )
            }
            .map(\.path)

        return .success(
            Coverage(
                percent: lines > 0 ? coveredLines * 100 / lines : 0,
                filesWithoutCoverage: filesWithoutCoverage,
                functionsCoverage: FunctionsCoverage(from: coverage),
                filesInCoverage: filesInCoverage(of: coverage, projectFiles: projectFiles),
                testsFailedWithCoverageOn: testsFailedWithCoverageOn
            )
        )
    }

    /// The project's own source files that `export`, llvm-cov's, names, by their path in the project, as `projectFiles`
    /// takes them, once each and in order.
    static func filesInCoverage(of export: LLVMCoverage, projectFiles: ProjectSourceFiles) -> [FilePath] {
        Set((export.data.first?.files ?? []).compactMap { projectFiles.pathInProject($0.filename) }).sorted()
    }
}

enum CoverageError: Error, Equatable {
    /// xcodebuild's coverage run couldn't be started, or left no result bundle whose report xccov could read.
    case build
    /// The command, such as `swift` or `llvm-cov`, couldn't be started.
    case couldNotRun(String)
    /// The coverage run didn't end within `buildTimeout`, these seconds, so it was killed.
    case timedOut(after: TimeInterval)
    /// The coverage run was ended by this signal.
    case endedBySignal(Int32)
    /// A test process of the coverage run crashed, named by its test bundle and signal where SwiftPM's line gives them,
    /// and `failedTests` failed. It left no profile, so the code it ran would read as never run.
    case testProcessCrashed(String, failedTests: FailedTestLine.FailedTests)
    /// A test process of the coverage run stopped before its tests finished, as one killed by SIGKILL does, which
    /// SwiftPM prints no line for, named by its test bundle and the test it was running where the output gives them,
    /// and `failedTests` failed. It left no profile, so the code it ran would read as never run.
    case testProcessUnfinished(String, failedTests: FailedTestLine.FailedTests)
    /// A test process of xcodebuild's coverage run crashed, or was stopped past its time allowance, named by its test
    /// bundle and the test it was running where the output gives them, and `failedTests` failed. Xcode keeps what the
    /// process counted, but the tests it was running never finished, so the code they would have run would read as
    /// never run.
    case testProcessRelaunched(String, failedTests: FailedTestLine.FailedTests)
    /// The coverage run failed with this exit status but named no failed test, as when the build fails, with the first
    /// line of its output that says `error:`.
    case runFailed(status: Int32, error: String?)
    case noBuildDirectory
    case noProfileData(atPath: String)
    case noTestBundles(inDirectory: String)
    /// llvm-profdata couldn't merge the profiles the test processes left after a test failed, saying this.
    case mergeFailed(String)
    /// llvm-cov failed, saying this.
    case llvmCovFailed(String)
    case unreadableReport
    /// The report covers none of the project's own source files.
    case noProjectFiles
    /// xccov's report of xcodebuild's coverage run covers none of the project's own source files, as its report of a
    /// package doesn't: it lists only the tests' files. The coverage then comes from llvm-cov's export.
    case noProjectFilesInXccovReport
    /// None of the products xccov says xcodebuild's coverage run built exists, for llvm-cov to read.
    case noBuiltProducts
    /// Where xcodebuild's coverage run left its profile couldn't be found: its result bundle wasn't in
    /// `<DerivedData>/Logs/Test`, nor its products in `<DerivedData>/Build/Products`, and `-showBuildSettings` gave no
    /// `BUILD_DIR`.
    case noXcodeBuildFolder
}

extension CoverageError {
    /// Why coverage couldn't be gathered, to follow "Gathering coverage failed: ".
    var reason: String {
        switch self {
        case .build:
            return "xcodebuild gave no coverage report"
        case let .couldNotRun(command):
            return "\(command) couldn't be started"
        case let .timedOut(seconds):
            return "the tests with coverage on didn't end within \(String(format: "%g", seconds)) s (buildTimeout), "
                + "so SwiftMutator stopped them"
        case let .endedBySignal(signal):
            return "the tests with coverage on were ended by signal \(signal)"
        case let .testProcessCrashed(process, failedTests):
            return Self.withoutProfile("a test process crashed with coverage on (\(process))", failedTests)
        case let .testProcessUnfinished(process, failedTests):
            return Self.withoutProfile(
                "a test process stopped before its tests finished with coverage on (\(process))",
                failedTests
            )
        case let .testProcessRelaunched(process, failedTests):
            return Self.naming(
                failedTests,
                after: "a test process crashed or was stopped with coverage on (\(process)), "
                    + "and Xcode relaunched it without finishing the tests it was running, "
                    + "so the code they would have run would read as never run"
            )
        case let .runFailed(status, error?):
            return "the coverage run failed (exit status \(status)): \(error)"
        case let .runFailed(status, nil):
            return "the coverage run failed (exit status \(status)) without naming a failed test or an error"
        case .noBuildDirectory:
            return "`swift test --show-codecov-path` didn't say where the build is"
        case let .noProfileData(path):
            return "there is no profile data at \(path)"
        case let .noTestBundles(directory):
            return "there is no test bundle in \(directory)"
        case let .mergeFailed(message):
            let failed = "a test failed with coverage on, "
                + "and llvm-profdata couldn't merge the profiles the test processes left"
            return message.isEmpty ? failed : "\(failed): \(message)"
        case let .llvmCovFailed(message):
            return message.isEmpty ? "llvm-cov failed" : "llvm-cov failed: \(message)"
        case .unreadableReport:
            return "llvm-cov's report couldn't be read"
        case .noProjectFiles:
            return "llvm-cov's report covers none of the project's source files"
        case .noProjectFilesInXccovReport:
            return "xccov's report covers none of the project's source files"
        case .noBuiltProducts:
            return "none of the products xccov says the coverage run built exists"
        case .noXcodeBuildFolder:
            return "the coverage run's profile couldn't be found: its result bundle isn't in <DerivedData>/Logs/Test, "
                + "nor its products in <DerivedData>/Build/Products, "
                + "and xcodebuild -showBuildSettings gave no BUILD_DIR"
        }
    }

    /// `ended`, what became of a test process that left no profile, then why that matters, then up to 5 of
    /// `failedTests`.
    private static func withoutProfile(_ ended: String, _ failedTests: FailedTestLine.FailedTests) -> String {
        naming(failedTests, after: ended + ", and without its profile the code it ran would read as never run")
    }

    /// `reason`, then up to 5 of `failedTests`.
    private static func naming(_ failedTests: FailedTestLine.FailedTests, after reason: String) -> String {
        guard failedTests.count > 0 else {
            return reason
        }
        let (names, more) = failedTests.named(upTo: FailedTestLine.coverageMessageLimit)
        return reason + "; tests that failed: " + names.joined(separator: ", ")
            + (more > 0 ? ", and \(more) more" : "")
    }
}
