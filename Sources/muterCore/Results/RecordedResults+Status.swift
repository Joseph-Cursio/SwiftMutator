import ArgumentParser
import Foundation

extension RecordedResults {
    /// What `swift-mutator report` says on standard error about the results file at `path`: how many mutants its
    /// report covers, how the run ended, that it tested one mutant alone if it did, which sessions tested its results,
    /// and the lines it skipped. No emoji, so the lines grep cleanly in CI logs.
    func statusLines(path: String) -> [String] {
        // `read` refuses a file without a header.
        guard let last = sessions.last else { return [] }
        return [
            "Report of \(latest.count) of \(last.header.mutantsDiscovered) mutants, from \(path): \(ending).",
        ] + [oneMutant, resultSources, skippedLines].compactMap { $0 }
    }

    /// That the run tested one mutant alone, which the score is of; nil for any other run.
    var oneMutant: String? {
        sessions.last?.header.mutant.map(MuterTestReport.oneMutantSentence)
    }

    /// How the run ended, from its last session's end line.
    var ending: String {
        sessions.last.map(Self.ending(of:)) ?? ""
    }

    /// Which sessions tested the report's results, when the file holds more than one session or results that `--reuse`
    /// kept: how many the last session tested, how many each earlier session tested, and how many `--reuse` kept, by
    /// the results file each was first tested in. Each result counts once, for the line the report takes for its key,
    /// so a result tested again counts for the session that tested it again. nil when the report is empty, and for a
    /// file of one session that kept nothing.
    var resultSources: String? {
        guard let last = sessions.last?.header.session, !latest.isEmpty else { return nil }
        var testedLast = 0
        var testedEarlier: [Int: Int] = [:]
        var kept: [String: Int] = [:]
        var notRun = 0
        for result in latest.values {
            if let origin = result.reusedFrom {
                kept[origin.resultsFile, default: 0] += 1
            } else if result.endedBy == .couldNotRun {
                notRun += 1
            } else if result.session == last {
                testedLast += 1
            } else {
                testedEarlier[result.session, default: 0] += 1
            }
        }
        guard sessions.count > 1 || !kept.isEmpty else { return nil }
        let tested = switch testedLast {
        case 0: "none were tested"
        case 1: "1 was tested"
        default: "\(testedLast) were tested"
        }
        let keptPhrase = Self.keptPhrase(kept)
        let notRunPhrase = notRun == 0
            ? nil
            : "\(notRun) didn't run, as \(notRun == 1 ? "it" : "they") couldn't build or start"
        guard sessions.count > 1 else {
            let also = notRunPhrase.map { ", \($0)," } ?? ""
            return keptPhrase.map { "Of these, \(tested)\(also) and \($0)." }
        }
        var phrases = ["\(tested) in the last session, session \(last)"]
        let earlier = testedEarlier.sorted { $0.key < $1.key }.map { "\($0.value) in session \($0.key)" }
        if earlier.count == 1 {
            phrases += earlier
        } else if earlier.count > 1 {
            phrases.append("\(testedEarlier.values.reduce(0, +)) in earlier ones (\(Logger.listed(earlier)))")
        }
        if let keptPhrase {
            phrases.append(keptPhrase)
        }
        if let notRunPhrase {
            phrases.append(notRunPhrase)
        }
        let final = phrases.removeLast()
        return "Of these, " + (phrases.isEmpty ? final : phrases.joined(separator: ", ") + ", and " + final) + "."
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

    /// The status the run exited with for the error it stopped on, as its last session's end line says, which `report`
    /// exits with too; nil when it didn't stop on one (`ResultsEnd.exitStatus`).
    var exitStatus: ExitCode? {
        sessions.last?.end?.exitStatus
    }

    /// How many of the mutants discovered have results, for a run that didn't finish and lacks some: `report` says it
    /// with its verdict on the score. nil once the last session finished, or when every mutant has a result.
    var unfinishedProgress: ScoreGate.Progress? {
        guard sessions.last?.end?.reason != .finished else { return nil }
        let discovered = headers.last?.mutantsDiscovered ?? latest.count
        guard latest.count < discovered else { return nil }
        return ScoreGate.Progress(results: latest.count, discovered: discovered)
    }

    /// How many results `--reuse` kept, `kept` counting them by the results file each was first tested in; nil when
    /// it kept none.
    private static func keptPhrase(_ kept: [String: Int]) -> String? {
        // A path can hold commas, as log folders' names do, so each comes last in its phrase, and a list of them is
        // said in parentheses.
        let files = kept.sorted { $0.key < $1.key }
        guard let first = files.first else { return nil }
        let total = "\(kept.values.reduce(0, +)) kept by --reuse"
        guard files.count > 1 else { return "\(total), tested in \(first.key)" }
        let each = ["\(first.value) tested in \(first.key)"] + files.dropFirst().map { "\($0.value) in \($0.key)" }
        return "\(total) (\(Logger.listed(each)))"
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

extension ResultsEnd {
    /// The status the session exited with, for one that stopped on an error, from the abort reason its `detail` names
    /// (`detail(for:)`), as the run did (`ExitCode.exitStatus(afterRunFailedWith:)`): that reason's kind's status
    /// (`MutationTestingAbortReason.Kind.exitStatus`), and `stoppedOnAnError` for any other error. nil for a session
    /// that finished or was interrupted.
    var exitStatus: ExitCode? {
        guard reason == .aborted else { return nil }
        let code = detail.map { String($0.prefix { $0 != "(" }) }
        return code.flatMap(MutationTestingAbortReason.Kind.init(rawValue:))?.exitStatus ?? .stoppedOnAnError
    }
}
