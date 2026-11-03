import Foundation

/// What an xcodebuild run's output shows went wrong with its simulator rather than with the mutant's tests. xcodebuild
/// exits with 65 for both, with no failed test, so such a run would otherwise count as a kill.
enum SimulatorTrouble: Equatable {
    /// The simulator didn't launch the app or its test runner: still busy with the run before ("Application failed
    /// preflight checks", reason Busy), or with another run's app on it ("Test crashed with signal kill before
    /// establishing connection"). A run on it again usually passes.
    case launch(line: String)
    /// The run's simulator is gone, as when it was deleted: every run on it fails the same way, without a test.
    case deviceGone(line: String)

    /// The line of the log that shows it.
    var line: String {
        switch self {
        case let .launch(line), let .deviceGone(line): line
        }
    }

    /// What `log` shows went wrong with the simulator, if anything, unless it shows a failed test, which makes the run
    /// the mutant's kill whatever else went wrong. A gone device comes before a failed launch: a run on it again
    /// wouldn't launch either. The line is the first that shows it in the summary after `Testing failed:`, which
    /// xcodebuild ends its output with, or else the first anywhere, without its indent, at most
    /// `FailedTestLine.lineLengthLimit` characters.
    static func first(inLog log: String) -> SimulatorTrouble? {
        // "\r\n" is a single Character, so a log with those line breaks isn't split at "\n" alone.
        let lines = log.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        guard !lines.contains(where: FailedTestLine.matches) else { return nil }
        let summary = lines.lastIndex { $0.hasPrefix("Testing failed:") }.map { lines[$0...] } ?? []
        for (trouble, signs) in [(Self.deviceGone, deviceGoneLines), (Self.launch, launchLines)] {
            let shows = { (line: Substring) in signs.contains { line.contains($0) } }
            if let line = summary.first(where: shows) ?? lines.first(where: shows) {
                let text = line.trimmingCharacters(in: .whitespaces)
                return trouble(String(text.prefix(FailedTestLine.lineLengthLimit)))
            }
        }
        return nil
    }

    /// What `run`, an xcodebuild run with `configuration`, shows went wrong with its simulator. Never anything for a
    /// run that passed or was cancelled, or another build system's run.
    static func of(_ run: TestRun, with configuration: MuterConfiguration) -> SimulatorTrouble? {
        guard configuration.buildSystem == .xcodebuild, run.outcome != .passed, run.ending != .cancelled else {
            return nil
        }
        return first(inLog: run.testLog)
    }

    /// Text that xcodebuild prints when the simulator didn't launch the app or its test runner. The launch services'
    /// own errors, nested in one another, then xcodebuild's own, which its summary repeats.
    private static let launchLines = [
        "Application failed preflight checks",
        "Simulator device failed to launch",
        "Failed to install or launch the test runner",
        "before establishing connection",
    ]

    /// Text that xcodebuild prints when the run's simulator is gone: before the run, when it can't resolve the
    /// `-destination`, or during it, when CoreSimulator no longer has the device.
    private static let deviceGoneLines = [
        "Unable to find a device matching the provided destination specifier",
        "No matching device (",
    ]
}

/// A mutant's run that the simulator failed to launch, which was run again in its place on the same worker.
struct LaunchFailure: Equatable {
    /// The line of its log that shows it (`SimulatorTrouble.launch`).
    let line: String
    let testLog: String
}

/// A mutant's run that the simulator failed to launch and that ran again, once the second run's result is written,
/// before its outcome is sent. Never counted in the progress, which counts the second run.
struct RepeatedRun {
    /// The outcome of the second run, which the results file records.
    let mutant: MutationTestOutcome.Mutation
    /// The worker both ran on.
    let worker: Int
    /// The line that shows the first run's failure to launch.
    let line: String
    /// The first run's log, kept under a name of its own (`MutationTestLog.launchFailedFileName(for:)`).
    let log: MutationTestLog
}
