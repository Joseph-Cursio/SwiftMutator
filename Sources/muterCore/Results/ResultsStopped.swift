import ArgumentParser
import Foundation

/// The one line of the results file of a run that stopped before its first mutant: a baseline or a build failed or ran
/// past `buildTimeout`, or a signal stopped the run (#117). It is the file's only line, with no header, so an older
/// SwiftMutator refuses the file as one with no header line, rather than read it as a run with no result, and this one
/// says why: `report` exits as the run did, and `--resume` and `--reuse` refuse it.
struct ResultsStopped: Codable, Equatable, Sendable {
    /// The step the run was in when it stopped.
    enum Step: String, Codable, Sendable {
        /// Any other step: copying the project, finding its files and mutants, mapping them, or making the xcodebuild
        /// workers' simulators.
        case preparing
        case coverageRun
        /// One of xcodebuild's builds for testing.
        case buildForTesting
        /// One of the baseline's runs in the mutated project.
        case baseline
        case directTestRun
        /// The worker clones' baselines.
        case workerBaselines
        /// The xcodebuild workers' runs with no mutant on, on their simulators.
        case workerCheckRuns
        case timedTestRun
    }

    /// Why the run stopped.
    enum Reason: String, Codable, Sendable {
        /// The step failed: a baseline that didn't pass, or a build for testing that didn't build.
        case failed
        /// The step ran past `buildTimeout`.
        case timedOut
        /// A signal stopped the run.
        case interrupted
    }

    private(set) var kind = "stopped" // swiftlint:disable:this unused_declaration - results file key; Codable writes it
    /// When the run started, and when it stopped.
    let startedAt: Date
    let stoppedAt: Date
    let step: Step
    let reason: Reason
    /// The abort's code, as an end line gives it (`ResultsEnd.detail(for:)`), with the worker it names; or, when
    /// `interrupted`, the signal's name, such as `SIGINT`.
    let detail: String?
    /// The limit, in seconds, of a step that `timedOut`.
    let limitSeconds: Double?
    /// The step's log, by its name in `logDirectory`, if it was kept or is still where it ran.
    let log: String?
    /// The tests the step's log shows failing, at most `FailedTestLine.killedByLimit`, and how many did; nil when the
    /// stop had no log to read, as a signal's doesn't.
    let failedTests: [FailedTestLine.FailedTest]?
    let failedTestCount: Int?
    let projectPath: String
    let logDirectory: String
    /// The results file of the run that this one, a `--resume`, was resuming, which it left as it was.
    let resuming: String?

    /// The status the run exited with, which `report` exits with too: a failed baseline's for a failed or timed-out
    /// step, and an abort's for a signal, as `report` gives for an interrupted shard, since it can't die of the signal.
    var exitStatus: ExitCode {
        reason == .interrupted ? .abortedMidRun : .baselineFailed
    }

    /// What `report` says of the file at `path`: why the run stopped, where its log is, the tests that failed, and, for
    /// a resume, the run it left as it was.
    func lines(path: String) -> [String] {
        var lines = ["The run in \(Logger.shellQuoted(path)) \(stoppedClause)."] + detailLines
        if let resuming {
            lines.append("It was resuming the run in \(Logger.shellQuoted(resuming)), which it left as it was: "
                + "--resume that file once this is fixed.")
        }
        return lines
    }

    /// What befell the run, after "the run": "stopped before its first mutant, so it has no result: the baseline run
    /// failed".
    var stoppedClause: String {
        "stopped before its first mutant, so it has no result: " + why
    }

    /// Where its log is, and the tests that failed.
    var detailLines: [String] {
        var lines: [String] = []
        if let log {
            lines.append("Its log is \(logDirectory.appendingPathComponent(log)).")
        }
        if let failedTests, let failedTestCount, failedTestCount > 0 {
            let more = failedTestCount - failedTests.count
            lines.append(failedTestCount == 1 ? "This test failed:" : "These \(failedTestCount) tests failed:")
            lines += failedTests.map { "  \($0.nameAndLocation)" } + (more > 0 ? ["  and \(more) more"] : [])
        }
        return lines
    }

    /// Why the run stopped, as a clause: "the baseline run failed".
    private var why: String {
        switch reason {
        case .failed:
            "\(stepName) failed"

        case .timedOut:
            "\(stepName) didn't end within \(limitSeconds.map { String(format: "%g", $0) } ?? "?") s (buildTimeout)"

        case .interrupted:
            "\(detail ?? "a signal") stopped it during \(stepName)"
        }
    }

    private var stepName: String {
        let worker = detail.flatMap(Self.worker(in:)).map { "worker \($0)'s" }
        return switch step {
        case .preparing: "its preparation, outside its builds and test runs"
        case .coverageRun: "the coverage run"
        case .buildForTesting: "the build for testing"
        case .baseline: "the baseline run"
        case .directTestRun: "the direct test run"
        case .workerBaselines: "\(worker ?? "a worker clone's") baseline run"
        case .workerCheckRuns: "\(worker ?? "a worker's") run with no mutant on"
        case .timedTestRun: "the timed test run"
        }
    }

    /// The worker an abort's code names, as `buildTimeoutReached(worker: 2)`.
    private static func worker(in detail: String) -> Int? {
        guard let start = detail.range(of: "(worker: "), detail.hasSuffix(")") else { return nil }
        return Int(detail[start.upperBound...].dropLast())
    }
}
