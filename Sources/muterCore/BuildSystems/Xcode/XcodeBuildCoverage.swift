import Foundation

final class XcodeBuildCoverage: BuildSystemCoverage {
    @Dependency(\.process)
    var process: ProcessFactory
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    /// What the coverage run printed, standard output then standard error, once `run` has run it.
    private(set) var coverageRunOutput: String?

    /// The architecture whose code llvm-cov reads in a universal binary: this Mac's, unless a test asks for another.
    private let architecture: String

    init(architecture: String = XcodeBuildCoverage.hostArchitecture) {
        self.architecture = architecture
    }

    /// The architecture SwiftMutator runs as, and so the tests it starts, as llvm-cov names it.
    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    func run(
        with configuration: MuterConfiguration
    ) -> Result<Coverage, CoverageError> {
        guard let testRun = runTestsWithCoverageEnabled(using: configuration) else {
            return .failure(.build)
        }
        let log = Self.log(of: testRun)
        coverageRunOutput = log
        if testRun.timedOut, let timeLimit = configuration.buildTimeout {
            return .failure(.timedOut(after: timeLimit))
        }
        guard testRun.succeeded else {
            return Self.failedTestsToKeep(in: testRun, log: log)
                .flatMap { coverage(configuration, printedBy: testRun, failedTests: $0) }
        }

        return coverage(configuration, printedBy: testRun, failedTests: nil)
    }

    /// The coverage in the result bundle whose path `testRun` printed, of a run in which `failedTests` failed: xccov's
    /// lines, and llvm-cov's regions.
    private func coverage(
        _ configuration: MuterConfiguration,
        printedBy testRun: CommandResult,
        failedTests: FailedTestLine.FailedTests?
    ) -> Result<Coverage, CoverageError> {
        guard let resultPath = resultBundle(printedBy: testRun),
              let report = runXccov(with: resultPath).flatMap(CoverageReport.init(json:))
        else {
            return .failure(.build)
        }

        return Self.coverage(
            of: report,
            projectRoot: fileManager.currentDirectoryPath,
            coverageThreshold: configuration.coverageThreshold
        )
        .map { lines in
            Coverage(
                percent: lines.percent,
                filesWithoutCoverage: lines.filesWithoutCoverage,
                functionsCoverage: functionsCoverage(configuration, builtProducts: report.builtProducts),
                testsFailedWithCoverageOn: failedTests
            )
        }
    }

    /// The tests that failed in a coverage run that failed, when the coverage in its result bundle can still be used:
    /// Xcode keeps what every test process counted, a failed test's too. Not when a test process crashed, or was
    /// stopped past its time allowance: Xcode keeps what it counted, but relaunches it without finishing the tests it
    /// was running, which for Swift Testing's parallel tests can be many, so the code they would have run would read as
    /// never run. And only when a failed test is named: a run that fails to build names none, and nor does one with
    /// parallel testing, whose lines, `Test case '…' failed on '…'`, read the same for a crash.
    private static func failedTestsToKeep(
        in testRun: CommandResult,
        log: String
    ) -> Result<FailedTestLine.FailedTests, CoverageError> {
        guard !testRun.endedBySignal else {
            return .failure(.endedBySignal(testRun.status))
        }
        let failedTests = FailedTestLine.failedTests(inLog: log)
        if let relaunched = unfinishedTestProcess(inLog: log) {
            return .failure(.testProcessRelaunched(relaunched, failedTests: failedTests))
        }
        guard failedTests.count > 0 else {
            return .failure(.runFailed(status: testRun.status, error: firstError(in: log)))
        }

        return .success(failedTests)
    }

    /// Which code no test ran, which xccov's report can't say, having no regions: from one `llvm-cov export` of
    /// `builtProducts`, the binary of each product the coverage run built, with the newest profile. `.null` if that
    /// can't be had, and the report's lines still say which files no test ran.
    private func functionsCoverage(_ configuration: MuterConfiguration, builtProducts: [String]) -> FunctionsCoverage {
        let binaries = builtProducts.flatMap(binaries(of:))
        guard !binaries.isEmpty,
              let buildDirectory = buildDirectory(configuration),
              let profile = testProfileData(at: buildDirectory),
              case let .success(export) = regionsExport(of: binaries, profile: profile),
              let coverage = try? JSONDecoder().decode(LLVMCoverage.self, from: export)
        else {
            return .null
        }

        return FunctionsCoverage(from: coverage)
    }

    /// llvm-cov's export of `binaries` with `profile`. llvm-cov reads a universal binary, as a build for every
    /// architecture makes, only for an architecture named, and then fails for a binary built only for another, as one
    /// for an Intel Mac's destination is. So one is named only if the export fails for want of it: this Mac's, whose
    /// code the tests ran.
    private func regionsExport(of binaries: [String], profile: String) -> Result<Data, CoverageError> {
        // xcodebuild runs only on macOS, where xcrun runs the selected Xcode's llvm-cov.
        let llvmCov = (executable: "/usr/bin/xcrun", arguments: ["llvm-cov"])
        let export = llvmCovExport(of: binaries, profile: profile, llvmCov: llvmCov)
        guard case let .failure(.llvmCovFailed(message)) = export, message.contains("universal binary") else {
            return export
        }

        return llvmCovExport(of: binaries, profile: profile, llvmCov: llvmCov, architecture: architecture)
    }

    /// The binaries that hold the code of `product`, one the coverage run built: the product, unless it doesn't exist,
    /// and after it, the `<App>.debug.dylib` beside an app's executable, which holds the app's code in a Debug build.
    /// xccov lists a package's library as a framework that isn't built when the library is linked into its tests, and
    /// llvm-cov fails on a file that doesn't exist.
    private func binaries(of product: String) -> [String] {
        guard fileManager.fileExists(atPath: product) else {
            return []
        }
        let debugDylib = product + ".debug.dylib"
        return fileManager.fileExists(atPath: debugDylib) ? [product, debugDylib] : [product]
    }

    /// The folder above `BUILD_DIR`, which holds the coverage profile, under `ProfileData`. xcodebuild prints each
    /// setting indented, once per target. With `BUILD_DIR=…` among the arguments, it first echoes that as given, under
    /// "Build settings from command line:", so the search starts at the first target's block.
    func buildDirectory(_ configuration: MuterConfiguration) -> String? {
        process().runProcess(
            url: configuration.testCommandExecutable,
            arguments: configuration.testCommandArguments + ["-showBuildSettings"]
        )
        .map { (settings: String) in
            settings.range(of: "Build settings for action").map { String(settings[$0.lowerBound...]) } ?? settings
        }
        .flatMap { $0.firstCaptureOf(#"^\s*BUILD_DIR = (.+)$"#, options: .anchorsMatchLines) }
        .map(\.trimmed)
        .flatMap(\.nilIfEmpty)
        .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    }

    private func runTestsWithCoverageEnabled(
        using configuration: MuterConfiguration
    ) -> CommandResult? {
        process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: configuration.enableCoverageArguments,
            timeLimit: configuration.buildTimeout
        )
    }

    /// The `.xcresult` bundle whose path the coverage run printed, whatever its exit status.
    private func resultBundle(printedBy testRun: CommandResult) -> String? {
        testRun.output.firstMatchOf("^.*.xcresult$", options: .anchorsMatchLines)
            .map(\.trimmed)
            .flatMap(\.nilIfEmpty)
    }

    private func runXccov(with result: String) -> Data? {
        process().runProcess(
            url: process().which("xcrun") ?? "",
            arguments: ["xccov", "view", "--report", "--json", result]
        )
    }

    /// The share of the project's lines the tests ran, and the files without coverage, by their path in the project.
    typealias LineCoverage = (percent: Int, filesWithoutCoverage: [FilePath])

    /// The coverage of the project's own source files in `report`, xccov's JSON: the share of their lines the tests
    /// ran, and the files at or below `coverageThreshold`, by their path in the project. Only targets other than tests
    /// count, and of their files only the project's own: the report also covers the packages the project depends on,
    /// and files Xcode generates. Fails if the report can't be read, or names none of the project's files.
    static func coverage(
        fromReport report: Data,
        projectRoot: String,
        coverageThreshold: Double
    ) -> Result<LineCoverage, CoverageError> {
        guard let report = CoverageReport(json: report) else {
            return .failure(.build)
        }

        return coverage(of: report, projectRoot: projectRoot, coverageThreshold: coverageThreshold)
    }

    private static func coverage(
        of report: CoverageReport,
        projectRoot: String,
        coverageThreshold: Double
    ) -> Result<LineCoverage, CoverageError> {
        // The derived data can be in the project, as `-derivedDataPath` can put it.
        let projectFiles = ProjectSourceFiles(root: projectRoot, buildFolders: report.derivedData)
        // A file built into several targets, such as an app and its extension, counts once, with the most of its lines
        // the tests ran in any of them.
        let files = Dictionary(
            report.targets
                .excludeTestTargets()
                .flatMap(\.files)
                .compactMap { file in projectFiles.pathInProject(file.path).map { ($0, file) } },
            uniquingKeysWith: { $0.coveredLines >= $1.coveredLines ? $0 : $1 }
        )
        .sorted { $0.key < $1.key }
        // xccov's report of a package tested through xcodebuild lists only its tests' files.
        guard !files.isEmpty else {
            return .failure(.noProjectFilesInXccovReport)
        }

        let lines = files.map(\.value.executableLines).reduce(0, +)
        let coveredLines = files.map(\.value.coveredLines).reduce(0, +)
        let filesWithoutCoverage = files
            .filter {
                ProjectSourceFiles.hasNoCoverage(
                    covered: $0.value.coveredLines,
                    of: $0.value.executableLines,
                    threshold: coverageThreshold
                )
            }
            .map(\.key)

        let percent = lines > 0 ? coveredLines * 100 / lines : 0
        return .success((percent: percent, filesWithoutCoverage: filesWithoutCoverage))
    }
}

/// What SwiftMutator reads of xccov's JSON report: each target, and how many of each of its files' lines the tests
/// could run and ran.
private struct CoverageReport: Decodable {
    let targets: [Target]
}

private extension CoverageReport {
    /// The report in `json`, xccov's output, or nil if it can't be read.
    init?(json: Data) {
        guard let report = try? JSONDecoder().decode(Self.self, from: json) else {
            return nil
        }
        self = report
    }

    /// The binary of each product the coverage run built, the tests' among them. The build folder holds more: those of
    /// other run destinations, and of targets since removed, whose functions would read as never run at lines that now
    /// hold other code.
    var builtProducts: [String] {
        targets.compactMap(\.buildProductPath)
    }

    /// The derived data the coverage run used, the folder above `Build/Products` in its products' paths, which also
    /// holds the packages the project depends on, under `SourcePackages`, and the files the build generates.
    var derivedData: [String] {
        Array(Set(builtProducts.compactMap { path in
            path.range(of: "/Build/Products/").map { String(path[..<$0.lowerBound]) }
        }))
    }

    struct Target: Decodable {
        let files: [File]
        let name: String
        /// The binary built for the target, such as `…/AppTests.xctest/Contents/MacOS/AppTests`.
        let buildProductPath: String?
    }
}

private extension CoverageReport.Target {
    struct File: Decodable {
        let path: String
        let coveredLines: Int
        let executableLines: Int
    }
}

private extension [CoverageReport.Target] {
    /// Leaves out the test targets, whose product is a `.xctest` bundle. xcodebuild names a package's test target
    /// without the `.xctest`, so only its build product shows it is one.
    func excludeTestTargets() -> [Element] {
        exclude { $0.name.hasSuffix(".xctest") || $0.buildProductPath?.contains(".xctest/") == true }
    }
}
