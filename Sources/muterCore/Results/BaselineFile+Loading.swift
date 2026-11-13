import Foundation
import Yams

extension BaselineFile {
    /// The keys of each mapping in the file, in the order they're saved.
    private static let topKeys = ["formatVersion", "swiftMutator", "score", "scope", "survivors"]
    private static let scoreKeys = ["killed", "scored"]
    private static let scopeKeys = ["operators", "skipCoverage", "configuration"]
    private static let configurationKeys = [
        "arguments", "buildSystem", "coverageThreshold", "exclude", "excludeCalls", "mutationTestTimeout",
    ]
    private static let survivorKeys = ["mutant", "outcome", "before", "after", "line"]

    /// The file's scope as YAML gives it (`Written`).
    private struct WrittenScope: Decodable {
        let operators: [String]
        let skipCoverage: Bool
        let configuration: BaselineScope.Configuration
    }

    /// A survivor's entry as YAML gives it (`Written`).
    private struct WrittenSurvivor: Decodable {
        let mutant: String
        let outcome: String
        let before: String
        let after: String
        let line: String?
    }

    /// The file as YAML gives it. A mutant and an outcome are checked once it's decoded: a decoder's errors say where,
    /// in its own words, and hide why.
    private struct Written: Decodable {
        let formatVersion: Int
        let swiftMutator: String
        let score: Score
        let scope: WrittenScope
        let survivors: [WrittenSurvivor]?
    }

    /// The baseline file at `path`, `~` expanded. Refused, with why (`BaselineRefused`): no file there, one that can't
    /// be read, text that isn't UTF-8 or YAML, a key it doesn't know, such as a misspelled one, a newer format, a score
    /// whose counts no run gives, as more killed than scored, and an entry that names no whole mutant, an outcome it
    /// doesn't know, or a mutant twice.
    static func load(at path: String, using fileManager: FileSystemManager) throws -> BaselineFile {
        let expanded = URL.expandingTilde(path)
        let refusal = { (problem: String) in BaselineRefused(path: path, reasons: [problem]) }
        guard let data = fileManager.contents(atPath: expanded) else {
            guard fileManager.fileExists(atPath: expanded) else {
                throw refusal("There is no baseline file there. Write one with --write-baseline.")
            }
            throw refusal("SwiftMutator can't read it.")
        }
        guard let text = String(data: data, encoding: .utf8) else { throw refusal("It isn't UTF-8.") }
        let written: Written
        do {
            let document = try Yams.load(yaml: text)
            if let version = (document as? [AnyHashable: Any])?["formatVersion"] as? Int, version > formatVersion {
                throw refusal(
                    "Its format is version \(version), newer than this SwiftMutator reads (\(formatVersion)). "
                        + "Use a SwiftMutator as new as the one that wrote it, or write a new one with "
                        + "--write-baseline."
                )
            }
            if let problem = unknownKey(in: document) { throw refusal(problem) }
            written = try YAMLDecoder().decode(Written.self, from: text)
        } catch let refused as BaselineRefused {
            throw refused
        } catch {
            throw refusal("It isn't a baseline file SwiftMutator can read: \(error)")
        }
        return try BaselineFile(path: path, written: written)
    }

    private init(path: String, written: Written) throws {
        let refusal = { (problem: String) in BaselineRefused(path: path, reasons: [problem]) }
        // A hand edit or a merge's conflict can leave counts no run gives, whose score `--max-score-drop` would
        // compare as if it were one: above 100%, or below 0, which turns the comparison around.
        let score = written.score
        guard score.killed >= 0, score.scored >= 0, score.killed <= score.scored else {
            throw refusal(
                "Its score counts killed \(score.killed) of \(score.scored) scored: give scored from 0 up, and "
                    + "killed from 0 to scored."
            )
        }
        var seen: Set<MutantKey> = []
        let survivors = try (written.survivors ?? []).map { entry in
            guard let mutant = MutantKey(wholeDescription: entry.mutant) else {
                throw refusal(
                    "\(entry.mutant) isn't a whole mutant key: give path:line:column Operator, as reports do."
                )
            }
            guard let outcome = BaselineSurvivor.Outcome(rawValue: entry.outcome) else {
                let outcomes = BaselineSurvivor.Outcome.allCases.map(\.rawValue)
                throw refusal(
                    "\(mutant) has the outcome \(entry.outcome): give \(outcomes.dropLast().joined(separator: ", "))"
                        + " or \(outcomes.last ?? "")."
                )
            }
            guard seen.insert(mutant).inserted else {
                throw refusal("\(mutant) is listed more than once.")
            }
            return BaselineSurvivor(
                mutant: mutant,
                outcome: outcome,
                before: entry.before,
                after: entry.after,
                line: entry.line
            )
        }
        self.init(
            path: path,
            swiftMutator: written.swiftMutator,
            score: written.score,
            scope: BaselineScope(
                operators: written.scope.operators,
                skipCoverage: written.scope.skipCoverage,
                configuration: written.scope.configuration
            ),
            survivors: survivors,
            formatVersion: written.formatVersion
        )
    }

    /// What's wrong with the first key in `document` that isn't one of the file's; nil when there's none.
    private static func unknownKey(in document: Any?) -> String? {
        guard let top = document as? [AnyHashable: Any] else { return nil }
        if let problem = unknown(in: top, known: topKeys, of: "the file") { return problem }
        if let score = top["score"] as? [AnyHashable: Any],
           let problem = unknown(in: score, known: scoreKeys, of: "score") {
            return problem
        }
        if let scope = top["scope"] as? [AnyHashable: Any] {
            if let problem = unknown(in: scope, known: scopeKeys, of: "scope") { return problem }
            if let configuration = scope["configuration"] as? [AnyHashable: Any],
               let problem = unknown(in: configuration, known: configurationKeys, of: "scope.configuration") {
                return problem
            }
        }
        for case let survivor as [AnyHashable: Any] in top["survivors"] as? [Any] ?? [] {
            if let problem = unknown(in: survivor, known: survivorKeys, of: "a survivor's entry") { return problem }
        }
        return nil
    }

    /// "colour isn't a key of scope: give operators, skipCoverage, configuration."; nil when `mapping` has no other key
    /// than `known`.
    private static func unknown(in mapping: [AnyHashable: Any], known: [String], of what: String) -> String? {
        guard let key = mapping.keys.map({ "\($0)" }).sorted().first(where: { !known.contains($0) }) else { return nil }
        return "\(key) isn't a key of \(what): give \(known.joined(separator: ", "))."
    }
}
