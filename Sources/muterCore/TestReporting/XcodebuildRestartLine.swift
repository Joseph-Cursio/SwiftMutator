import Foundation

/// xcodebuild's line for a test runner it launches again, after the runner crashed, exited partway through, or ran a
/// test past XCTest's own time allowance. Each of those fails the test in xcodebuild's summary, so a run that went on
/// to its end would fail. xcodebuild then runs the tests left, in a runner of its own, which makes a run with a crash
/// take far longer than its baseline: a crash in every test reaches the time limit before the summary.
///
/// It names no signal, so it can't tell a crash that running out of stack caused from any other
/// (`MutationTestingAbortReason.crashThatMayBeAStackOverflow`).
enum XcodebuildRestartLine {
    static let prefix = "Restarting after unexpected exit, crash, or test timeout"

    /// The first line of `log` that starts with xcodebuild's restart line, as xcodebuild prints it, on a line of its
    /// own, so text a test prints inside another line doesn't count.
    static func first(inLog log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix(prefix) }
            .map(String.init)
    }
}
