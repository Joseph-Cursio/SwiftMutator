import Foundation

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
