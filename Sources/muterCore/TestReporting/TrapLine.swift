import Foundation

/// The Swift runtime's message for a trap: `file.swift:12: Fatal error`, `Precondition failed` or `Assertion failed`,
/// for `fatalError`, `precondition` and `assert`, followed by `: message` only when there is one. A process can print
/// it and go on, as a test that catches the trap (Nimble's `throwAssertion`) does, so it shows a crash only in a run
/// whose passing baseline never printed one.
enum TrapLine {
    /// The first line of `log` that holds the runtime's message, after `: ` or at its start.
    static func first(inLog log: String) -> String? {
        let whole = NSRange(log.startIndex..., in: log)
        return regEx.firstMatch(in: log, range: whole)
            .flatMap { Range($0.range, in: log) }
            .map { range in String(log[log.lineRange(for: range)]).trimmingCharacters(in: .newlines) }
    }

    private static var regEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(
            #"(^|: )(Fatal error|Precondition failed|Assertion failed)(: |$)"#,
            .anchorsMatchLines
        )
    }
}
