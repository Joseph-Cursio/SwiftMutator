import Foundation

/// Why SwiftMutator won't resume the run in a results file: every reason it found, in one message.
struct ResumeRefused: Error, Equatable, CustomStringConvertible {
    let path: String
    let reasons: [ResumeRefusal]
    /// Whether it was refused before the project was copied and the last copy removed, which the message then says.
    let beforeTheCopy: Bool

    var description: String {
        let file = Logger.shellQuoted(path)
        var lines: [String]
        if reasons.count == 1, let only = reasons.first, case .inUse = only {
            // The run isn't in question, only who has its file.
            lines = ["SwiftMutator won't resume the run in \(file): \(only)"]
        } else {
            lines = [
                "SwiftMutator won't resume the run in \(file), so that no result is reused that this run might not "
                    + "reproduce:",
            ]
            for reason in reasons {
                let reasonLines = "\(reason)".components(separatedBy: "\n")
                lines.append("  - " + (reasonLines.first ?? ""))
                lines += reasonLines.dropFirst().map { "    " + $0 }
            }
        }
        if beforeTheCopy {
            lines.append("Nothing was copied or removed.")
        }
        return lines.joined(separator: "\n")
    }
}

/// One reason a run can't be resumed, and what would let it be.
enum ResumeRefusal: Equatable, CustomStringConvertible {
    /// Another process holds the results file's lock. The file's last session's process and host, if it has one.
    case inUse(lastProcess: Int32?, lastHost: String?)
    /// A configuration key that some outcome depends on.
    case configurationChanged(ResumeCheck.Difference)
    /// `operators`, `filesToMutate` or `skipCoverage`: which mutants are tested.
    case selectionChanged(ResumeCheck.Difference)
    /// What identifies the SwiftMutator build, the toolchain or the SDK, which `--force-resume` lets through.
    case needsForce(ResumeCheck.Difference)
    /// Project files that changed, and that no `--resume-ignoring` glob matches.
    case filesChanged([ProjectTree.FileChange])
    case testPlanRun
    /// The last session was written by a SwiftMutator from before `--resume`, which recorded no project files.
    case noProjectTree
    /// `-o` names the results file itself.
    case reportWouldReplaceTheResultsFile(String)

    /// How many changed files are named, each with a `--resume-ignoring` flag; the rest are counted.
    static let changedFilesNamed = 10

    var description: String {
        switch self {
        case let .inUse(process, host):
            var writer = process.map { " by process \($0)" } ?? ""
            if let host, !host.isEmpty {
                writer += " on \(host)"
            }
            return "another SwiftMutator run holds its lock."
                + (writer.isEmpty ? "" : " The file's last session was written\(writer).")
        case let .configurationChanged(difference):
            return "\(difference.name) \(difference.change(absent: "not set")). "
                + "A configuration change needs a new run."
        case let .selectionChanged(difference):
            return "\(difference.name) \(difference.change(absent: "not set")). "
                + "A change to which mutants are tested needs a new run."
        case let .needsForce(difference):
            let subject = "\(ResumeCheck.subject(of: difference.name)) (\(difference.name))"
            let change = difference.was == nil && difference.isNow == nil
                ? "is unknown, so it may have changed"
                : difference.change(absent: "unknown")
            return "\(subject) \(change). --force-resume reuses the results anyway."
        case let .filesChanged(changes):
            return Self.describe(changes)
        case .testPlanRun:
            return "A run that tests a test plan (run-without-mutating) can't be resumed."
        case .noProjectTree:
            return "The file's last session recorded no project files, as SwiftMutator didn't before --resume, "
                + "so nothing shows that they haven't changed. A new run is needed."
        case let .reportWouldReplaceTheResultsFile(path):
            return "-o \(Logger.shellQuoted(path)) is the results file itself, which the report would replace. "
                + "Write the report to another file."
        }
    }

    /// A `--resume-ignoring` glob that matches `path` alone, as `partition(by:)` reads globs: `*`, `?`, `[` and `\`
    /// escaped with a backslash.
    static func glob(matching path: String) -> String {
        var glob = ""
        for character in path {
            if "*?[\\".contains(character) {
                glob.append("\\")
            }
            glob.append(character)
        }
        return glob
    }

    /// The changed files, up to `changedFilesNamed` of them by name, and the flags that would let those through,
    /// ready to paste.
    private static func describe(_ changes: [ProjectTree.FileChange]) -> String {
        let named = changes.prefix(changedFilesNamed)
        let others = changes.count - named.count
        let one = changes.count == 1
        let files = named.map { "\($0.path) (\($0.kind.rawValue))" }.joined(separator: ", ")
            + (others > 0 ? ", and \(others) more" : "")
        let flags = named.map { "--resume-ignoring " + Logger.shellQuoted(glob(matching: $0.path)) }
            .joined(separator: " ")
            + (others > 0 ? ", plus globs for the other \(others)" : "")
        return [
            "\(changes.count) project file\(one ? "" : "s") changed since the run stopped: \(files).",
            "If \(one ? "it" : "they") can't change any test's result: \(flags)",
            "Mutants in a changed source file are tested again either way.",
        ].joined(separator: "\n")
    }
}
