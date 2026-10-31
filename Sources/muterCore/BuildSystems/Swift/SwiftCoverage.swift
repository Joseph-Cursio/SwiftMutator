import Foundation

/// SwiftPM's coverage of a project, from one `llvm-cov export` over every test bundle the coverage run builds. Swift
/// Build, the default since Swift 6.4, builds a bundle for each test target, and each bundle maps only the code its
/// target links, so a report of one bundle leaves out the files only the others reach. The native build system builds
/// one bundle for the whole package.
final class SwiftCoverage: BuildSystemCoverage {
    @Dependency(\.process)
    var process: ProcessFactory
    @Dependency(\.fileManager)
    private var fileManager: FileSystemManager

    /// What the coverage run printed, standard output then standard error, once `run` has run it.
    private(set) var coverageRunOutput: String?

    /// The platform whose build folder and LLVM tools to expect: the host's, unless a test asks for another.
    private let platform: Platform

    /// The platforms SwiftMutator builds for, which lay out a build folder and find their LLVM tools differently.
    enum Platform {
        case darwin
        case linux

        /// The platform SwiftMutator was built for, and so runs on.
        static var host: Platform {
            #if os(Linux)
            .linux
            #else
            .darwin
            #endif
        }
    }

    init(platform: Platform = .host) {
        self.platform = platform
    }

    func run(
        with configuration: MuterConfiguration
    ) async -> Result<Coverage, CoverageError> {
        let executable = configuration.testCommandExecutable
        // Only the coverage run builds and runs tests, so only it has a time limit.
        guard let testRun = await process().runCommand(
            url: executable,
            arguments: configuration.enableCoverageArguments,
            timeLimit: configuration.buildTimeout
        ) else {
            return .failure(.couldNotRun(executable))
        }
        let log = Self.log(of: testRun)
        coverageRunOutput = log
        // Before anything else: killed at its limit, it would read as ended by a signal, or as failed tests whose
        // profiles could be merged.
        if testRun.timedOut, let timeLimit = configuration.buildTimeout {
            return .failure(.timedOut(after: timeLimit))
        }
        guard testRun.succeeded else {
            switch Self.failedTestsToMerge(in: testRun, log: log) {
            case let .success(failedTests): return await coverage(configuration, failedTests: failedTests)
            case let .failure(error): return .failure(error)
            }
        }

        return await coverage(configuration, failedTests: nil)
    }

    /// The coverage of the build the coverage run used, exported from every test bundle in it. After a run in which
    /// `failedTests` failed, SwiftPM merged no profile, so the profiles the test processes left are merged first.
    private func coverage(
        _ configuration: MuterConfiguration,
        failedTests: FailedTestLine.FailedTests?
    ) async -> Result<Coverage, CoverageError> {
        guard let binPath = await buildDirectory(configuration) else {
            return .failure(.noBuildDirectory)
        }
        let profile = binPath + "/codecov/default.profdata"
        if failedTests != nil, let error = await mergeProfiles(
            in: binPath + "/codecov",
            into: profile,
            testCommand: configuration.testCommandExecutable
        ) {
            return .failure(error)
        }
        guard fileManager.fileExists(atPath: profile) else {
            return .failure(.noProfileData(atPath: profile))
        }
        let bundles = await testBundles(in: binPath, testTargets: testTargets(configuration))
        guard !bundles.isEmpty else {
            return .failure(.noTestBundles(inDirectory: binPath))
        }

        return await llvmCovExport(
            of: bundles,
            profile: profile,
            llvmCov: llvmTool("llvm-cov", nextTo: configuration.testCommandExecutable)
        )
        .flatMap { export in
            Self.coverage(
                fromExport: export,
                projectRoot: fileManager.currentDirectoryPath,
                coverageThreshold: configuration.coverageThreshold,
                testsFailedWithCoverageOn: failedTests
            )
        }
    }

    /// The tests that failed in a coverage run that failed, when the profiles its test processes left can stand in for
    /// the one SwiftPM merges only when every test passes. Not when a test process crashed, or stopped before its tests
    /// finished: it left no profile, so the code it ran would read as never run. And only when a failed test is named,
    /// which shows the tests started, so SwiftPM had emptied `codecov` first; a build that fails leaves an earlier
    /// run's profiles there.
    private static func failedTestsToMerge(
        in testRun: CommandResult,
        log: String
    ) -> Result<FailedTestLine.FailedTests, CoverageError> {
        guard !testRun.endedBySignal else {
            return .failure(.endedBySignal(testRun.status))
        }
        let failedTests = FailedTestLine.failedTests(inLog: log)
        if let crashed = crashedTestProcess(inErrors: testRun.errors) {
            return .failure(.testProcessCrashed(crashed, failedTests: failedTests))
        }
        if let unfinished = unfinishedTestProcess(inLog: log) {
            return .failure(.testProcessUnfinished(unfinished, failedTests: failedTests))
        }
        guard failedTests.count > 0 else {
            return .failure(.runFailed(status: testRun.status, error: firstError(in: log)))
        }

        return .success(failedTests)
    }

    /// Merges the profiles the test processes left in `codecov`, one each, into `profile`, as SwiftPM does when every
    /// test passes. Swift Testing's are named `Swift Testing<signature>.<pid>.profraw`, with a space. `testCommand`,
    /// the test command's executable, says where llvm-profdata is.
    private func mergeProfiles(in codecov: String, into profile: String, testCommand: String) async -> CoverageError? {
        let profiles = ((try? fileManager.contentsOfDirectory(atPath: codecov)) ?? [])
            .filter { $0.hasSuffix(".profraw") }
            .sorted()
            .map { "\(codecov)/\($0)" }
        guard !profiles.isEmpty else {
            return .noProfileData(atPath: codecov)
        }
        let llvmProfdata = llvmTool("llvm-profdata", nextTo: testCommand)
        guard let merge = await process().runCommand(
            url: llvmProfdata.executable,
            arguments: llvmProfdata.arguments + ["merge", "-sparse"] + profiles + ["-o", profile]
        ) else {
            return .couldNotRun("llvm-profdata")
        }

        return merge.succeeded ? nil : .mergeFailed(Self.firstLine(of: merge.errors))
    }

    /// The build the coverage run used, from `swift test <arguments> --show-codecov-path`, which follows the run's own
    /// arguments, such as `--scratch-path`, and prints `<build>/codecov/<package>.json`.
    func buildDirectory(_ configuration: MuterConfiguration) async -> String? {
        guard let result = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: configuration.testCommandArguments + ["--show-codecov-path"]
        ),
            result.succeeded,
            let path = result.output.split(separator: "\n").last.map(String.init)?.trimmed.nilIfEmpty
        else {
            return nil
        }

        return URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    /// The file llvm-cov reads for each test bundle in `binPath`, in name order.
    ///
    /// Swift Build names a bundle after its test target. One left by a test target the package no longer has maps the
    /// paths it was built at. Copied with the project, those are the project's own, which coverage leaves out. But a
    /// build folder that outlives the copy, such as an absolute `--scratch-path`, can hold one built at the copy's
    /// paths, and its functions would read as never run at lines that now hold other code. So when any bundle is named
    /// after one of `testTargets`, only those are kept. The native build system names its one bundle after the package.
    private func testBundles(in binPath: String, testTargets: Set<String>?) -> [String] {
        testBundleFiles(in: binPath, testTargets: testTargets).map { "\(binPath)/\($0.file)" }
    }

    /// The test bundles in `binPath` that `testBundles(in:testTargets:)` keeps, by name and file in the folder, in
    /// name order.
    func testBundleFiles(in binPath: String, testTargets: Set<String>?) -> [(name: String, file: String)] {
        let bundles = testBundles(among: (try? fileManager.contentsOfDirectory(atPath: binPath)) ?? [])
        let ofTestTargets = bundles.filter { testTargets?.contains($0.name) ?? false }
        return (ofTestTargets.isEmpty ? bundles : ofTestTargets).sorted { $0.name < $1.name }
    }

    /// Each test bundle among `files`, those in a build folder, by its name and the file in the folder that llvm-cov
    /// reads. On macOS that is the executable in the bundle. On Linux, the native build system's bundle is itself the
    /// executable, and Swift Build makes for each test target a `<name>-test-runner` that loads the tests from the
    /// `<name>.so` next to it. Any other `.so` is a library.
    private func testBundles(among files: [String]) -> [(name: String, file: String)] {
        switch platform {
        case .darwin:
            return files.filter { $0.hasSuffix(".xctest") }.map { bundle in
                let name = String(bundle.dropLast(".xctest".count))
                return (name, "\(bundle)/Contents/MacOS/\(name)")
            }
        case .linux:
            let inFolder = Set(files)
            return files.compactMap { file in
                if file.hasSuffix(".xctest") {
                    return (String(file.dropLast(".xctest".count)), file)
                }
                let name = String(file.dropLast(".so".count))
                return file.hasSuffix(".so") && inFolder.contains(name + "-test-runner") ? (name, file) : nil
            }
        }
    }

    /// The package's test targets, from `swift package describe`, or nil if it can't say.
    func testTargets(_ configuration: MuterConfiguration) async -> Set<String>? {
        await testTargetSources(configuration).map { Set($0.keys) }
    }

    /// The package's test targets, each with its source files' paths in the target's folder, from `swift package
    /// describe`, or nil if it can't say.
    func testTargetSources(_ configuration: MuterConfiguration) async -> [String: [String]]? {
        guard let described = await process().runCommand(
            url: configuration.testCommandExecutable,
            arguments: ["package", "describe", "--type", "json"]
        ),
            described.succeeded,
            let package = try? JSONDecoder().decode(PackageDescription.self, from: Data(described.output.utf8))
        else {
            return nil
        }

        return Dictionary(
            package.targets.filter { $0.type == "test" }.map { ($0.name, $0.sources ?? []) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private struct PackageDescription: Decodable {
        let targets: [Target]

        struct Target: Decodable {
            let name: String
            let type: String
            let sources: [String]?
        }
    }

    /// How to run the LLVM tool `name`, such as `llvm-cov`: the executable, and the arguments before the tool's own.
    /// On macOS, xcrun runs the selected Xcode's. On Linux, it is the one next to `testCommand`, the test command's
    /// executable, with its links resolved, as `/usr/bin/swift` is often a link into the toolchain. SwiftPM takes the
    /// one next to `swiftc`, and one found elsewhere on `PATH`, such as a distribution's, may not read the toolchain's
    /// profiles. Without one there, it is whichever comes first on `PATH`.
    private func llvmTool(_ name: String, nextTo testCommand: String) -> (executable: String, arguments: [String]) {
        switch platform {
        case .darwin:
            return ("/usr/bin/xcrun", [name])
        case .linux:
            let inToolchain = URL(fileURLWithPath: testCommand.canonicalPath)
                .deletingLastPathComponent()
                .appendingPathComponent(name)
                .path
            return fileManager.fileExists(atPath: inToolchain) ? (inToolchain, []) : ("/usr/bin/env", [name])
        }
    }

    /// The test process that crashed in a run whose standard error is `errors`, by its test bundle and signal, as
    /// SwiftPM's line for it gives them: `error: Process '…/xctest …/CoreTests.xctest' exited with unexpected signal
    /// code 5`, or for Swift Testing's helper, `'…/swiftpm-testing-helper --test-bundle-path
    /// …/CoreTests.xctest/Contents/MacOS/CoreTests …'`. On Linux, Swift Build's process is the test target's runner,
    /// `'…/CoreTests-test-runner …'`, which names it instead. Any line that mentions a signal code counts, however
    /// else it's worded, so a crash is never taken for a failed test. nil when none crashed.
    private static func crashedTestProcess(inErrors errors: String) -> String? {
        guard let line = errors.split(whereSeparator: \.isNewline)
            .first(where: { $0.lowercased().contains("signal code") })
            .map({ FailedTestLine.withoutColours($0).trimmed })
        else {
            return nil
        }
        let bundle = line.firstCaptureOf(#"([^/\s']+\.xctest)(?=[/'\s]|$)"#)
            ?? line.firstCaptureOf(#"([^/\s']+-test-runner)(?=['\s]|$)"#)
        let signal = line.firstCaptureOf(#"signal code ([0-9]+)"#, options: .caseInsensitive).map { "signal \($0)" }
        let named = [bundle, signal].compactMap { $0 }
        return named.isEmpty ? String(line.prefix(FailedTestLine.lineLengthLimit)) : named.joined(separator: ", ")
    }
}
