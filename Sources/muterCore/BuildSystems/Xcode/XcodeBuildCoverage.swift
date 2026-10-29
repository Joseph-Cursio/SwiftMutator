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
    ) async -> Result<Coverage, CoverageError> {
        guard let testRun = await runTestsWithCoverageEnabled(using: configuration) else {
            return .failure(.build)
        }
        let log = Self.log(of: testRun)
        coverageRunOutput = log
        if testRun.timedOut, let timeLimit = configuration.buildTimeout {
            return .failure(.timedOut(after: timeLimit))
        }
        guard testRun.succeeded else {
            switch Self.failedTestsToKeep(in: testRun, log: log) {
            case let .success(failedTests): return await coverage(configuration, printedBy: testRun, failedTests: failedTests)
            case let .failure(error): return .failure(error)
            }
        }

        return await coverage(configuration, printedBy: testRun, failedTests: nil)
    }

    /// The coverage in the result bundle whose path `testRun` printed, of a run in which `failedTests` failed: xccov's
    /// lines, and llvm-cov's regions. xccov's report of a Swift package tested through xcodebuild names only the tests'
    /// files: their bundle holds the library's code, which xccov counts for no target. So then the lines come from
    /// llvm-cov's export too, as SwiftPM's do.
    private func coverage(
        _ configuration: MuterConfiguration,
        printedBy testRun: CommandResult,
        failedTests: FailedTestLine.FailedTests?
    ) async -> Result<Coverage, CoverageError> {
        guard let resultBundle = resultBundle(printedBy: testRun),
              let report = await runXccov(with: resultBundle).flatMap(CoverageReport.init(json:))
        else {
            return .failure(.build)
        }
        let projectRoot = fileManager.currentDirectoryPath
        let derivedData = report.derivedData(resultBundle: resultBundle)
        let export = { await self.export(configuration, builtProducts: report.builtProducts, derivedData: derivedData) }

        switch Self.coverage(
            of: report,
            projectRoot: projectRoot,
            buildFolders: derivedData,
            coverageThreshold: configuration.coverageThreshold
        ) {
        case let .success(lines):
            return .success(
                Coverage(
                    percent: lines.percent,
                    filesWithoutCoverage: lines.filesWithoutCoverage,
                    functionsCoverage: Self.functionsCoverage(of: await export()),
                    testsFailedWithCoverageOn: failedTests
                )
            )
        case .failure(.noProjectFilesInXccovReport):
            return await export().flatMap { export in
                Self.coverage(
                    fromExport: export,
                    projectRoot: projectRoot,
                    coverageThreshold: configuration.coverageThreshold,
                    buildFolders: derivedData,
                    testFiles: report.testFiles,
                    testsFailedWithCoverageOn: failedTests
                )
            }
        case let .failure(error):
            return .failure(error)
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

    /// Which code no test ran, which xccov's report can't say, having no regions: from `export`, llvm-cov's. `.null` if
    /// that couldn't be had, and the report's lines still say which files no test ran.
    private static func functionsCoverage(of export: Result<Data, CoverageError>) -> FunctionsCoverage {
        guard case let .success(export) = export,
              let coverage = try? JSONDecoder().decode(LLVMCoverage.self, from: export)
        else {
            return .null
        }

        return FunctionsCoverage(from: coverage)
    }

    /// One `llvm-cov export` of `builtProducts`, the binary of each product the coverage run built that exists, with
    /// the newest profile in the build folders of `derivedData`, the run's, or why it couldn't be had.
    private func export(
        _ configuration: MuterConfiguration,
        builtProducts: [String],
        derivedData: [String]
    ) async -> Result<Data, CoverageError> {
        let binaries = builtProducts.flatMap(binaries(of:))
        guard !binaries.isEmpty else {
            return .failure(.noBuiltProducts)
        }
        let buildFolders = await buildFolders(configuration, derivedData: derivedData)
        guard !buildFolders.isEmpty else {
            return .failure(.noXcodeBuildFolder)
        }
        guard let profile = await testProfileData(at: buildFolders) else {
            return .failure(.noProfileData(atPath: buildFolders.joined(separator: " or ")))
        }

        return await regionsExport(of: binaries, profile: profile)
    }

    /// The folders that can hold the coverage run's profile, the newest of which is the run's: `Build` in each of
    /// `derivedData`, the run's, and the folder above `BUILD_DIR`. Xcode keeps the profile in the result bundle's
    /// derived data even when `SYMROOT` or `BUILD_DIR` move the products, but with the products and their intermediate
    /// files when its Build Location setting is Custom or Shared Folder, which can leave an earlier run's profile in
    /// the derived data. A Swift package's scheme has no `BUILD_DIR`: `-showBuildSettings` prints no settings for it,
    /// saying "Supported platforms for the buildables in the current scheme is empty".
    private func buildFolders(_ configuration: MuterConfiguration, derivedData: [String]) async -> [String] {
        (derivedData.map { $0 + "/Build" } + [await buildDirectory(configuration)].compactMap { $0 })
            .reduce(into: []) { folders, folder in
                if !folders.contains(folder) { folders.append(folder) }
            }
    }

    /// llvm-cov's export of `binaries` with `profile`. llvm-cov reads a universal binary, as a build for every
    /// architecture makes, only for an architecture named, and then fails for a binary built only for another, as one
    /// for an Intel Mac's destination is. So one is named only if the export fails for want of it: this Mac's, whose
    /// code the tests ran.
    private func regionsExport(of binaries: [String], profile: String) async -> Result<Data, CoverageError> {
        // xcodebuild runs only on macOS, where xcrun runs the selected Xcode's llvm-cov.
        let llvmCov = (executable: "/usr/bin/xcrun", arguments: ["llvm-cov"])
        let export = await llvmCovExport(of: binaries, profile: profile, llvmCov: llvmCov)
        guard case let .failure(.llvmCovFailed(message)) = export, message.contains("universal binary") else {
            return export
        }

        return await llvmCovExport(of: binaries, profile: profile, llvmCov: llvmCov, architecture: architecture)
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

    /// The folder above `BUILD_DIR`, which holds the coverage profile, under `ProfileData`, unless `SYMROOT` or
    /// `BUILD_DIR` moved the products out of the derived data. xcodebuild prints each setting indented, once per
    /// target. With `BUILD_DIR=…` among the arguments, it first echoes that as given, under "Build settings from
    /// command line:", so the search starts at the first target's block.
    func buildDirectory(_ configuration: MuterConfiguration) async -> String? {
        let settings: String? = await process().runProcess(
            url: configuration.testCommandExecutable,
            arguments: configuration.testCommandArguments + ["-showBuildSettings"]
        )
        return settings
            .map { settings in
                settings.range(of: "Build settings for action").map { String(settings[$0.lowerBound...]) } ?? settings
            }
            .flatMap { $0.firstCaptureOf(#"^\s*BUILD_DIR = (.+)$"#, options: .anchorsMatchLines) }
            .map(\.trimmed)
            .flatMap(\.nilIfEmpty)
            .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    }

    private func runTestsWithCoverageEnabled(
        using configuration: MuterConfiguration
    ) async -> CommandResult? {
        await process().runCommand(
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

    private func runXccov(with result: String) async -> Data? {
        await process().runProcess(
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

        return coverage(
            of: report,
            projectRoot: projectRoot,
            buildFolders: report.derivedData,
            coverageThreshold: coverageThreshold
        )
    }

    /// `buildFolders` are the derived data, whose files never count: `-derivedDataPath` can put it in the project.
    private static func coverage(
        of report: CoverageReport,
        projectRoot: String,
        buildFolders: [FilePath],
        coverageThreshold: Double
    ) -> Result<LineCoverage, CoverageError> {
        let projectFiles = ProjectSourceFiles(root: projectRoot, buildFolders: buildFolders)
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
        // xccov's report of a package tested through xcodebuild lists only its tests' files, so `run` reads llvm-cov's
        // export instead.
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
        Set(builtProducts.compactMap { path in
            path.range(of: "/Build/Products/").map { String(path[..<$0.lowerBound]) }
        })
        .sorted()
    }

    /// The derived data the coverage run used: the folder above `Logs/Test` in `resultBundle`, the path of its result
    /// bundle, which also holds the run's profile, under `Build/ProfileData`, and then that of its products. Those of
    /// a Swift package whose folder isn't named after it are in other derived data, named after the folder, with the
    /// same hash, and no profile: `PkgProbe_mutated-<hash>` rather than `PkgProbe-<hash>`, as in SwiftMutator's copy
    /// of a project. `-resultBundlePath` moves the result bundle, and `SYMROOT` or `BUILD_DIR` the products, but
    /// neither moves the profile. So with `-resultBundlePath`, such a package's profile can't be found, unless
    /// `-derivedDataPath` puts all of it in one folder.
    func derivedData(resultBundle: String) -> [String] {
        let ofResultBundle = resultBundle.range(of: "/Logs/Test/")
            .map { [String(resultBundle[..<$0.lowerBound])] } ?? []
        return ofResultBundle + derivedData.exclude(ofResultBundle.contains)
    }

    /// The files the test targets build, which can be outside a `Tests` folder, as those of a package's test target
    /// with a `path` of its own are.
    var testFiles: [String] {
        targets.filter(\.isTest).flatMap(\.files).map(\.path)
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

    /// Whether this is a test target, whose product is a `.xctest` bundle. xcodebuild names a package's test target
    /// without the `.xctest`, so only its build product shows it is one.
    var isTest: Bool {
        name.hasSuffix(".xctest") || buildProductPath?.contains(".xctest/") == true
    }
}

private extension [CoverageReport.Target] {
    func excludeTestTargets() -> [Element] {
        exclude(\.isTest)
    }
}
