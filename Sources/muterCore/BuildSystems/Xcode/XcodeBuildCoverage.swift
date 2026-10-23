import Foundation

final class XcodeBuildCoverage: BuildSystemCoverage {
    @Dependency(\.process)
    var process: ProcessFactory

    func run(
        with configuration: MuterConfiguration
    ) -> Result<Coverage, CoverageError> {
        let testRun = runTestsWithCoverageEnabled(using: configuration)
        if testRun?.timedOut == true, let timeLimit = configuration.buildTimeout {
            return .failure(.timedOut(after: timeLimit))
        }
        guard let resultPath = testRun.flatMap(resultBundle(printedBy:)),
              let report = runXccov(with: resultPath)
        else {

            return .failure(.build)
        }

        let untested = extractUntested(
            from: report,
            coverageThreshold: configuration.coverageThreshold
        )

        let percent = extractCoverage(from: report)
        let functionsCoverage = functionsCoverage(configuration)

        let projectCoverage = Coverage(
            percent: percent,
            filesWithoutCoverage: untested,
            functionsCoverage: functionsCoverage
        )

        return .success(projectCoverage)
    }

    /// The folder above `BUILD_DIR`, which holds both the test bundles, under `Products`, and the coverage profile,
    /// under `ProfileData`. xcodebuild prints each setting indented, once per target. With `BUILD_DIR=…` among the
    /// arguments, it first echoes that as given, under "Build settings from command line:", so the search starts at
    /// the first target's block.
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

    private func runXccov(with result: String) -> CoverageReport? {
        guard let output: Data = process().runProcess(
            url: process().which("xcrun") ?? "",
            arguments: ["xccov", "view", "--report", "--json", result]
        )
        else {
            return nil
        }

        return try? JSONDecoder().decode(CoverageReport.self, from: output)
    }

    private func extractUntested(
        from report: CoverageReport,
        coverageThreshold: Double
    ) -> [String] {
        report.targets
            .excludeTestTargets()
            .flatMap(\.files)
            .filter { $0.lineCoverage <= coverageThreshold }
            .map(\.path)
    }

    private func extractCoverage(from report: CoverageReport) -> Int {
        report.targets
            .excludeTestTargets()
            .map(\.lineCoverage)
            .map { Int($0 * 100) }
            .first ?? 0
    }
}

private struct CoverageReport: Decodable {
    let targets: [Target]
}

private extension CoverageReport {
    struct Target: Decodable {
        let files: [File]
        let name: String
        let lineCoverage: Double
    }
}

private extension CoverageReport.Target {
    struct File: Decodable {
        let lineCoverage: Double
        let path: String
    }
}

private extension [CoverageReport.Target] {
    func excludeTestTargets() -> [Element] {
        exclude { $0.name.contains("xctest") }
    }
}
