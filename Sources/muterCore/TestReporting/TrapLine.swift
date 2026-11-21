import Foundation

/// The Swift runtime's message for a trap: `file.swift:12: Fatal error`, `Precondition failed` or `Assertion failed`,
/// for `fatalError`, `precondition` and `assert`, followed by `: message` only when there is one. A process can print
/// it and go on, as a test that catches the trap (Nimble's `throwAssertion`) does, so it shows a crash only in a run
/// whose passing baseline never printed one.
enum TrapLine {
    /// Whether `line` (one line, without its line break) holds the runtime's message, as `first(inLog:)` finds it: what
    /// stops an xcodebuild run at a crash (`TestLogFollower`), as a Swift Testing test's crash under xcodebuild prints
    /// no other line.
    static func matches(_ line: some StringProtocol) -> Bool {
        // Rules out almost every line before the regex runs.
        guard messages.contains(where: { line.contains($0) }) else { return false }
        let text = FailedTestLine.withoutColours(line)
        return regEx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first line of `log` that holds the runtime's message, after `: ` or at its start, colour codes aside
    /// (`matches(_:)`), so a line that would stop a run is the one a passing run's lookalike check finds.
    static func first(inLog log: String) -> String? {
        log.split(whereSeparator: \.isNewline)
            .first(where: matches)
            .map(String.init)
    }

    private static let messages = ["Fatal error", "Precondition failed", "Assertion failed"]

    private static var regEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"(^|: )(Fatal error|Precondition failed|Assertion failed)(: |$)"#)
    }
}
