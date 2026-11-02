import Foundation

extension RecordedResults {
    /// What `swift-mutator report` says on standard error about the results file at `path`: how many mutants its
    /// report covers, how the run ended, and the lines it skipped. No emoji, so the lines grep cleanly in CI logs.
    func statusLines(path: String) -> [String] {
        // `read` refuses a file without a header.
        guard let last = sessions.last else { return [] }
        let shard = last.header.shard.map { " in shard \($0.index) of \($0.count)" } ?? ""
        return [
            "Report of \(latest.count) of \(last.header.mutantsDiscovered) mutants\(shard), from \(path): \(ending).",
        ] + [skippedLines].compactMap { $0 }
    }

    /// How the run ended, from its last session's end line.
    var ending: String {
        sessions.last.map(Self.ending(of:)) ?? ""
    }

    /// The lines skipped, by number; nil when none were.
    var skippedLines: String? {
        guard !unreadableLines.isEmpty else { return nil }
        let noun = unreadableLines.count == 1 ? "line" : "lines"
        let cutOff = endsWithCutOffLine ? "; the last was cut off as it was written" : ""
        return "Skipped \(unreadableLines.count) \(noun) that didn't read: "
            + unreadableLines.map(String.init).joined(separator: ", ") + cutOff + "."
    }

    /// Whether the run stopped on an error, as its last session's end line says: `report` then exits as the run did.
    var stoppedOnAnError: Bool {
        sessions.last?.end?.reason == .aborted
    }

    /// How `session` ended, from its end line.
    private static func ending(of session: Session) -> String {
        guard let end = session.end else {
            return "the run has no end line, so it is still running, or it was killed or crashed"
        }
        switch end.reason {
        case .finished:
            return "the run finished"
        case .interrupted:
            return "the run was interrupted" + (end.detail.map { " by \($0)" } ?? "")
        case .aborted:
            return "the run stopped on an error" + (end.detail.map { " (\($0))" } ?? "")
        }
    }
}
