import Foundation

/// Where a report's results came from: the results files, which `report`, `--resume` and `--reuse` read, how many
/// sessions made them, then the SwiftMutator build, the toolchain and the settings the mutants were tested with, as the
/// last session that tested any recorded them. A session with nothing left to test, which tests none, doesn't count,
/// unless it is the only one. For a merged report, the sessions are every shard's added up, and the rest is the first
/// shard's that tested any. The JSON report and `summary.json` hold it as `run`.
struct RunDetails: Codable, Equatable {
    /// The results files the report is of: the run's, or each shard's for a merged report.
    let resultsFiles: [String]
    /// How many sessions made the results: the last session's number, more than 1 when the run was resumed. For a
    /// merged report, each shard's added up.
    let sessions: Int
    let swiftMutator: Provenance.Build
    let toolchain: Provenance.Toolchain
    /// The workers the mutants were tested with; 0 when no session tested any, as for a `--reuse` with nothing to test.
    let workers: Int
    /// The time limit for a mutant's run; nil when none was set.
    let timeoutSeconds: Double?
    /// Whether that limit is the default, from a timed test run or the baseline, rather than configured.
    let timeoutIsDefault: Bool
    /// The configuration as loaded, under its own keys.
    let configuration: MuterConfiguration

    /// The details of `files`, each a results file's path and its headers, in the order they were written; nil
    /// without a header.
    init?(of files: [(path: String, headers: [ResultsHeader])]) {
        guard let last = files.first?.headers.last else { return nil }
        let tested = files.lazy.compactMap { $0.headers.last { $0.workers > 0 } }.first ?? last
        resultsFiles = files.map(\.path)
        sessions = files.reduce(0) { $0 + ($1.headers.last?.session ?? 0) }
        swiftMutator = tested.provenance.swiftMutator
        toolchain = tested.provenance.toolchain
        workers = tested.workers
        timeoutSeconds = tested.timeoutSeconds
        timeoutIsDefault = tested.timeoutIsDefault
        configuration = tested.configuration
    }

    /// What the plain and HTML reports say of it, a line each:
    ///
    ///     Results file: /…/results.jsonl (2 sessions)
    ///     SwiftMutator: 1.4.0, executable SHA-256 3f9a…
    ///     Toolchain: Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)
    ///     Workers: 4; time limit per mutant: 24 s, the default
    var lines: [String] {
        let files = resultsFiles.count == 1 ? "Results file: " : "Results files: "
        // One session a file needs no saying.
        let sessionCount = sessions > resultsFiles.count ? " (\(sessions) sessions)" : ""
        let sha = swiftMutator.executableSHA256.map { ", executable SHA-256 \($0)" } ?? ""
        let toolchainLine = toolchain.testCommandVersion?
            .split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        let limit = timeoutSeconds.map { seconds in
            "; time limit per mutant: \(Logger.seconds(seconds))" + (timeoutIsDefault ? ", the default" : "")
        } ?? "; no time limit"
        return [
            files + resultsFiles.joined(separator: ", ") + sessionCount,
            "SwiftMutator: \(swiftMutator.version)\(sha)",
            toolchainLine.map { "Toolchain: \($0)" },
            workers > 0 ? "Workers: \(workers)\(limit)" : "Workers: none, as no mutant was left to test",
        ].compactMap(\.self)
    }
}
