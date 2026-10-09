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

    func run(
        with configuration: MuterConfiguration
    ) -> Result<Coverage, CoverageError>

    func buildDirectory(_ configuration: MuterConfiguration) -> String?
}

extension BuildSystemCoverage {
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

    func testProfileData(at path: String) -> String? {
        guard let profiles = process().find(atPath: path, byName: "*.profdata") else {
            return nil
        }

        let lines = profiles.components(separatedBy: "\n")

        return lines.first ?? profiles.trimmed
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
    /// The tests failed with coverage on, with this exit status or signal.
    case testsFailed(status: Int32, bySignal: Bool)
    case noBuildDirectory
    case noProfileData(atPath: String)
    case noTestBundles(inDirectory: String)
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
        case let .testsFailed(status, bySignal: true):
            return "the tests with coverage on were ended by signal \(status)"
        case let .testsFailed(status, bySignal: false):
            return "the tests with coverage on failed (exit status \(status)), and SwiftPM saves no coverage then"
        case .noBuildDirectory:
            return "`swift test --show-codecov-path` didn't say where the build is"
        case let .noProfileData(path):
            return "there is no profile data at \(path)"
        case let .noTestBundles(directory):
            return "there is no test bundle in \(directory)"
        case let .llvmCovFailed(message):
            return message.isEmpty ? "llvm-cov failed" : "llvm-cov failed: \(message)"
        case .unreadableReport:
            return "llvm-cov's report couldn't be read"
        case .noProjectFiles:
            return "llvm-cov's report covers none of the project's source files"
        }
    }
}
