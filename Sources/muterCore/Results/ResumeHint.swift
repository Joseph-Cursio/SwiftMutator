import Foundation

/// The command that continues a stopped run: SwiftMutator as it was started, resuming from the run's results file.
enum ResumeHint {
    /// `swift-mutator`, then `arguments` without an earlier `--resume` and its value, or `--force-resume`, then
    /// `--resume` and `resultsFile`, each quoted only where a shell would split it.
    ///
    /// A resumed session's results file is the one this run continues, or the log folder that holds it, so `resultsFile`
    /// replaces it. The header of a session `--force-resume` let through records the build and toolchain it ran with,
    /// so the next session needs no force. `--resume-ignoring` stays: changed files a session's results don't depend
    /// on are as likely to change again before the next one.
    static func command(continuing arguments: [String], from resultsFile: String) -> String {
        var kept: [String] = []
        var skipsValue = false
        for argument in arguments {
            if skipsValue {
                skipsValue = false
                continue
            }
            if argument == "--resume" {
                skipsValue = true
                continue
            }
            if argument.hasPrefix("--resume=") || argument == "--force-resume" {
                continue
            }
            kept.append(argument)
        }
        return (["swift-mutator"] + kept.map(Logger.shellWord) + ["--resume", Logger.shellQuoted(resultsFile)])
            .joined(separator: " ")
    }
}
