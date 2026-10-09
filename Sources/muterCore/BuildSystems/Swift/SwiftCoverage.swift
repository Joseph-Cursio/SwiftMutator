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

    func run(
        with configuration: MuterConfiguration
    ) -> Result<Coverage, CoverageError> {
        let executable = configuration.testCommandExecutable
        guard let testRun = process().runCommand(url: executable, arguments: configuration.enableCoverageArguments)
        else {
            return .failure(.couldNotRun(executable))
        }
        // SwiftPM writes no profile data when a test fails, and merging what the test processes left would read the
        // code of any that crashed as never run.
        guard testRun.succeeded else {
            return .failure(.testsFailed(status: testRun.status, bySignal: testRun.endedBySignal))
        }
        guard let binPath = buildDirectory(configuration) else {
            return .failure(.noBuildDirectory)
        }
        let profile = binPath + "/codecov/default.profdata"
        guard fileManager.fileExists(atPath: profile) else {
            return .failure(.noProfileData(atPath: profile))
        }
        let bundles = testBundles(in: binPath)
        guard let first = bundles.first else {
            return .failure(.noTestBundles(inDirectory: binPath))
        }

        let objects = [first] + bundles.dropFirst().flatMap { ["-object", $0] }
        let arguments = ["llvm-cov", "export"] + objects + ["-instr-profile", profile]
        #if os(Linux)
        let llvmCov = "/usr/bin/env"
        #else
        let llvmCov = "/usr/bin/xcrun"
        #endif
        guard let export = process().runCommand(url: llvmCov, arguments: arguments) else {
            return .failure(.couldNotRun("llvm-cov"))
        }
        guard export.succeeded else {
            return .failure(.llvmCovFailed(Self.firstLine(of: export.errors)))
        }

        return Self.coverage(
            fromExport: Data(export.output.utf8),
            projectRoot: fileManager.currentDirectoryPath,
            coverageThreshold: configuration.coverageThreshold
        )
    }

    /// The build the coverage run used, from `swift test <arguments> --show-codecov-path`, which follows the run's own
    /// arguments, such as `--scratch-path`, and prints `<build>/codecov/<package>.json`.
    func buildDirectory(_ configuration: MuterConfiguration) -> String? {
        guard let result = process().runCommand(
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

    /// The executable of each test bundle in `binPath`, in name order. On macOS a bundle holds its executable; on Linux
    /// the bundle is the executable.
    private func testBundles(in binPath: String) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: binPath)) ?? [])
            .filter { $0.hasSuffix(".xctest") }
            .sorted()
            .map { bundle in
                #if os(Linux)
                return "\(binPath)/\(bundle)"
                #else
                let name = String(bundle.dropLast(".xctest".count))
                return "\(binPath)/\(bundle)/Contents/MacOS/\(name)"
                #endif
            }
    }

    /// The coverage of the project's own source files in `export`, llvm-cov's JSON: the share of their lines the tests
    /// ran, the files at or below `coverageThreshold`, by their path in the project, and the regions no test ran.
    /// The export also covers test files and dependencies, which don't count, and gives absolute paths.
    static func coverage(
        fromExport export: Data,
        projectRoot: String,
        coverageThreshold: Double
    ) -> Result<Coverage, CoverageError> {
        guard let coverage = try? JSONDecoder().decode(LLVMCoverage.self, from: export),
              let report = coverage.data.first
        else {
            return .failure(.unreadableReport)
        }

        let roots = Set([projectRoot, projectRoot.canonicalPath]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let files = report.files.compactMap { file -> (path: String, lines: LLVMCoverage.Lines)? in
            guard let root = roots.first(where: file.filename.hasPrefix) else {
                return nil
            }
            let path = String(file.filename.dropFirst(root.count))
            return isTestOrBuildFile(path) ? nil : (path, file.summary.lines)
        }
        guard !files.isEmpty else {
            return .failure(.noProjectFiles)
        }

        let lines = files.map(\.lines.count).reduce(0, +)
        let coveredLines = files.map(\.lines.covered).reduce(0, +)
        // A file with no lines to run has nothing to mutate, and saying it has no coverage would be wrong.
        let filesWithoutCoverage = files
            .filter { $0.lines.count > 0 && $0.lines.percent <= coverageThreshold }
            .map(\.path)

        return .success(
            Coverage(
                percent: lines > 0 ? coveredLines * 100 / lines : 0,
                filesWithoutCoverage: filesWithoutCoverage,
                functionsCoverage: FunctionsCoverage(from: coverage)
            )
        )
    }

    /// A file in a `.build` folder, such as that of a package in a subfolder, or a test file, as discovery tells them:
    /// one in a `Tests` folder, or whose name ends in `Tests.swift`. `path` is relative to the project.
    private static func isTestOrBuildFile(_ path: String) -> Bool {
        let folders = path.split(separator: "/").dropLast()
        return folders.contains(".build") || folders.contains("Tests") || path.hasSuffix("Tests.swift")
    }

    private static func firstLine(of text: String) -> String {
        text.split(separator: "\n").first.map { String($0).trimmed } ?? ""
    }
}
