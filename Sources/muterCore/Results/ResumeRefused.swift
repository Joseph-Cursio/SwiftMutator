import Foundation

/// Why SwiftMutator won't resume the run in a results file, or reuse its results: every reason it found, in one
/// message.
struct ResumeRefused: Error, Equatable, CustomStringConvertible {
    let path: String
    let reasons: [ResumeRefusal]
    /// Whether it was refused before the project was copied and the last copy removed, which the message then says.
    let beforeTheCopy: Bool
    /// Whether `--reuse` asked for the results, rather than `--resume`, which the message's flags then name.
    let isReuse: Bool

    init(path: String, reasons: [ResumeRefusal], beforeTheCopy: Bool, isReuse: Bool = false) {
        self.path = path
        self.reasons = reasons
        self.beforeTheCopy = beforeTheCopy
        self.isReuse = isReuse
    }

    /// Whether the only reason is that another run holds the file's lock, so the run itself isn't in question.
    /// `LoadResumeState` gives that reason alone.
    var isInUse: Bool {
        guard reasons.count == 1, case .inUse = reasons.first else { return false }
        return true
    }

    var description: String {
        let file = Logger.shellQuoted(path)
        var lines: [String]
        if isInUse, let only = reasons.first {
            // The run isn't in question, only who has its file.
            lines = ["SwiftMutator won't resume the run in \(file): \(only)"]
        } else {
            let refusal = isReuse ? "reuse the results in" : "resume the run in"
            lines = [
                "SwiftMutator won't \(refusal) \(file), so that no result is reused that this run might not "
                    + "reproduce:",
            ]
            for reason in reasons {
                let reasonLines = reason.describe(reusing: isReuse).components(separatedBy: "\n")
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
