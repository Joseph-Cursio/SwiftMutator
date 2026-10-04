import Foundation

/// The output line that shows a test failed. Any failed test kills a mutant, so its run can stop there
/// (`stopAtFirstFailure`) without changing its outcome.
enum FailedTestLine {
    /// Whether `line` (one line, without its line break) shows a failed test:
    /// - Swift Testing's line for an issue, printed when the issue is recorded:
    ///   `✘ Test sum() recorded an issue at SumTests.swift:12:5: …`. "an issue" is exactly a failing
    ///   one: a known issue reads "a known issue" (━), a warning "a warning" (⚠︎).
    /// - XCTest's line for a test that ended failed: `Test Case '-[Module.Class test]' failed (0.01 seconds).`
    ///
    /// Anchored at the start of the line, so failure text a test prints, or a parameterized test's
    /// argument quoted inside another line, doesn't match.
    static func matches(_ line: some StringProtocol) -> Bool {
        // Each check rules out almost every line before any regex runs.
        if line.contains("recorded an issue"), firstMatch(swiftTestingIssueRegEx, in: withoutColours(line)) {
            return true
        }
        return line.hasPrefix("Test Case '") && firstMatch(xctestFailureRegEx, in: String(line))
    }

    /// The first line of `log` that shows a failed test, without colour codes.
    static func first(inLog log: String) -> String? {
        // "\r\n" is a single Character, so a log with those line breaks isn't split at "\n" alone.
        log.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .first(where: matches)
            .map(withoutColours)
    }

    /// `line` without its ANSI colour codes.
    static func withoutColours(_ line: some StringProtocol) -> String {
        let text = String(line)
        guard text.contains("\u{1B}") else { return text }
        return ansiEscapeRegEx.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    /// The symbol is ✘, or SF Symbols' xmark.diamond.fill (U+100884) when /Library/Fonts/SF-Pro.ttf is
    /// installed, which gets an extra space when ANSI codes are on. Tag colour dots (●) may follow it.
    private static var swiftTestingIssueRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(
            #"^[\x{2718}\x{100884}] +(?:\x{25CF}+ +)?(?:Test|Suite) .+? recorded an issue(?: at | with [0-9]+ arguments? |: )"#
        )
    }

    private static var xctestFailureRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"^Test Case '[^']*' failed \("#)
    }

    private static var ansiEscapeRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(#"\x{1B}\[[0-9;]*m"#)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
