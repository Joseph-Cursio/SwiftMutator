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
    /// What the coverage run printed, once `run` has run it, for the run's log folder; nil if it didn't run, or if
    /// nothing of it is kept.
    var coverageRunOutput: String? { get }

    func run(
        with configuration: MuterConfiguration
    ) -> Result<Coverage, CoverageError>

    func buildDirectory(_ configuration: MuterConfiguration) -> String?
}

extension BuildSystemCoverage {
    /// xcodebuild's coverage run keeps none of its output.
    var coverageRunOutput: String? { nil }

    func runWithCoverageEnabled(using configuration: MuterConfiguration) -> String? {
        let result: String? = process().runProcess(
            url: configuration.testCommandExecutable,
            arguments: configuration.enableCoverageArguments
        )
        .flatMap(\.nilIfEmpty)
        .map(\.trimmed)

        return result
    }

    func functionsCoverage(_ configuration: MuterConfiguration) -> FunctionsCoverage {
        guard let buildDirectory = buildDirectory(configuration) else {
            return .null
        }

        guard let xctestExecutable = xctestExecutable(at: buildDirectory) else {
            return .null
        }

        guard let testBinary = testBinary(at: xctestExecutable) else {
            return .null
        }

        guard let testProfile = testProfileData(at: buildDirectory) else {
            return .null
        }

        guard let reportJson = llvmCovJsonReport(
            withExecutableAt: testBinary,
            coverageProfile: testProfile
        )?.data(using: .utf8)
        else {
            return .null
        }

        guard let coverageData = try? JSONDecoder().decode(LLVMCoverage.self, from: reportJson) else {
            return .null
        }

        return FunctionsCoverage(from: coverageData)
    }

    func xctestExecutable(at buildDirectory: String) -> String? {
        process().find(atPath: buildDirectory, byName: "*.xctest").map(\.trimmed)
    }

    func testBinary(at path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent

        return process().findExecutable(atPath: url.path, byName: name)
    }

    /// The newest profile under `path`. Xcode keeps one per run destination, `ProfileData/<device>/Coverage.profdata`,
    /// and leaves the other destinations' in place. `find` lists them in no set order, and `llvm-cov` reads a stale one
    /// without failing: every function added since then counts as never run, so its mutants would be skipped.
    func testProfileData(at path: String) -> String? {
        let profiles = (process().find(atPath: path, byName: "*.profdata") ?? "")
            .components(separatedBy: "\n")
            .map(\.trimmed)
            .filter { !$0.isEmpty }
        guard profiles.count > 1 else {
            return profiles.first
        }

        return process().runProcess(url: "/bin/ls", arguments: ["-t"] + profiles)
            .flatMap { $0.components(separatedBy: "\n").first?.trimmed.nilIfEmpty }
    }

    func llvmCovJsonReport(withExecutableAt executablePath: String, coverageProfile: String) -> String? {
        #if os(Linux)
        let url = process().which("llvm-cov")
        let arguments = [
            "export",
            executablePath,
            "-instr-profile",
            coverageProfile,
            "--ignore-filename-regex=.build|Tests",
        ]
        #else
        let url = process().which("xcrun")
        let arguments = [
            "llvm-cov",
            "export",
            executablePath,
            "-instr-profile",
            coverageProfile,
            "--ignore-filename-regex=.build|Tests",
        ]
        #endif
        return process().runProcess(
            url: url ?? "",
            arguments: arguments
        )
        .flatMap(\.nilIfEmpty)
        .map(\.trimmed)
    }
}

enum CoverageError: Error, Equatable {
    /// xcodebuild's coverage run or its report failed.
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
        }
    }

    /// `ended`, what became of a test process that left no profile, then why that matters, then up to 5 of
    /// `failedTests`.
    private static func withoutProfile(_ ended: String, _ failedTests: FailedTestLine.FailedTests) -> String {
        let reason = ended + ", and without its profile the code it ran would read as never run"
        guard failedTests.count > 0 else {
            return reason
        }
        let (names, more) = failedTests.named(upTo: FailedTestLine.coverageMessageLimit)
        return reason + "; tests that failed: " + names.joined(separator: ", ")
            + (more > 0 ? ", and \(more) more" : "")
    }
}
