import Foundation

/// The output line that shows a test process crashed: SwiftPM's report of one ended by a signal, which
/// `DirectTestRun`'s script prints as SwiftPM does. A crash kills a mutant, whatever the other test processes
/// would do, so its run can stop there (`stopAtFirstFailure`) as at a failed test, and score as a runtime error.
enum CrashLine {
    /// Whether `line` (one line, without its line break) shows a test process ended by a crash's signal:
    /// `error: Process '…/CoreTests.xctest' exited with unexpected signal code 5`, or from older versions,
    /// `error: Exited with signal code 4`.
    ///
    /// Anchored at the start of the line, so crash text a test prints inside another line doesn't match. The Swift
    /// runtime's `Fatal error:` line doesn't count: a process can print it and still exit 0, and its signal line
    /// follows it when the process dies of it. Nor do the signals that stop rather than crash a process: SIGKILL,
    /// which stopping a run sends, and SIGHUP, SIGINT and SIGTERM, which a Ctrl-C or a supervisor sends, so that such a
    /// run waits for SwiftMutator's own signal (`MutationTestingDelegate.mayHaveEndedByAnOutsideSignal`) instead of
    /// being recorded as a crash.
    static func matches(_ line: some StringProtocol) -> Bool {
        // Rules out almost every line before the regex runs.
        guard line.contains("signal code") else { return false }
        let text = FailedTestLine.withoutColours(line)
        return crashRegEx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first line of `log` that shows a crash, without colour codes.
    static func first(inLog log: String) -> String? {
        log.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .first(where: matches)
            .map(FailedTestLine.withoutColours)
    }

    private static var crashRegEx: NSRegularExpression {
        NSRegularExpression.regexWithPattern(
            #"^(?:error: )?(?:Process '.*' exited|Exited) with (?:unexpected )?signal code (?!(?:1|2|9|15)\b)[0-9]+\b"#
        )
    }
}
