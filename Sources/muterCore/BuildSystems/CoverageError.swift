import Foundation

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
        guard failedTests.total > 0 else {
            return reason
        }
        let (names, more) = failedTests.named(upTo: FailedTestLine.coverageMessageLimit)
        return reason + "; tests that failed: " + names.joined(separator: ", ")
            + (more > 0 ? ", and \(more) more" : "")
    }
}
