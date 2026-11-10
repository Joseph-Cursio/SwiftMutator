import Foundation
import Yams

/// What a person decided about a surviving mutant. It never changes a score: a label is a person's word, which a CI
/// job's threshold shouldn't rest on.
enum TriageLabel: String, Codable, CaseIterable {
    case missingTest = "missing-test"
    case equivalent
    case outOfScope = "out-of-scope"
    case toolLimitation = "tool-limitation"

    /// "missing test".
    var words: String {
        rawValue.replacingOccurrences(of: "-", with: " ")
    }

    /// "missing-test, equivalent, out-of-scope or tool-limitation".
    static var listed: String {
        let names = allCases.map(\.rawValue)
        return names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
    }
}

/// One mutant's label in the triage file. A key holds its mutant's line and column, which any edit above it moves, so
/// an entry also holds what its mutant changes (`TriageMatches`). Those three are optional, for an entry written by
/// hand: without them it applies at its key alone, and can't follow its code.
struct TriageEntry: Equatable {
    let mutant: MutantKey
    let label: TriageLabel
    let note: String?
    /// The mutant's snapshot, what it replaces and what with.
    let before: String?
    let after: String?
    /// The line it changes, without the spaces around it; nil when its change spans lines, or its file had changed
    /// since the run the entry was made from.
    let line: String?

    init(
        mutant: MutantKey,
        label: TriageLabel,
        note: String? = nil,
        before: String? = nil,
        after: String? = nil,
        line: String? = nil
    ) {
        self.mutant = mutant
        self.label = label
        self.note = note
        self.before = before
        self.after = after
        self.line = line?.trimmingCharacters(in: .whitespaces)
    }
}

extension TriageEntry {
    /// This entry at `key`, where its code now is.
    func moved(to key: MutantKey) -> TriageEntry {
        TriageEntry(mutant: key, label: label, note: note, before: before, after: after, line: line)
    }
}

extension TriageEntry: Encodable {
    private enum CodingKeys: String, CodingKey {
        case mutant
        case label
        case note
        case before
        case after
        case line
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mutant.description, forKey: .mutant)
        try container.encode(label.rawValue, forKey: .label)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(before, forKey: .before)
        try container.encodeIfPresent(after, forKey: .after)
        try container.encodeIfPresent(line, forKey: .line)
    }
}

/// The labels people gave surviving mutants, in `muter.triage.yml` beside the configuration, which is meant to be
/// committed. Reading it changes no result, and `ProjectTree` leaves it out, so labelling a mutant refuses no
/// `--resume` and tests nothing again in a `--reuse`.
struct TriageFile: Equatable {
    static let fileName = "muter.triage.yml"

    /// Where it was read from, or is saved to.
    let path: String
    var entries: [TriageEntry]

    /// The file as YAML gives it. A mutant and a label are checked once it's decoded: a decoder's errors say where, in
    /// its own words, and hide why.
    private struct Written: Decodable {
        struct Entry: Decodable {
            let mutant: String
            let label: String
            let note: String?
            let before: String?
            let after: String?
            let line: String?
        }

        let mutants: [Entry]?
    }

    private struct Saved: Encodable {
        let mutants: [TriageEntry]
    }

    /// `muter.triage.yml` in `folder`.
    static func path(in folder: String) -> String {
        (folder as NSString).appendingPathComponent(fileName)
    }

    /// The file at `path`; nil when there is none. A file with no entries is one with none to apply. Whatever a save
    /// wouldn't keep is refused, as saving over it would lose it unsaid: a file that can't be read, text that isn't
    /// UTF-8, and a key it doesn't know, such as a misspelled one. Only comments are lost.
    static func load(at path: String, using fileManager: FileSystemManager) throws -> Self? {
        guard let data = fileManager.contents(atPath: path) else {
            guard fileManager.fileExists(atPath: path) else { return nil }
            throw MuterError.literal(reason: "Could not read \(path): SwiftMutator can't open it")
        }
        return try Self(path: path, entries: entries(in: data, path: path))
    }

    private static func entries(in data: Data, path: String) throws -> [TriageEntry] {
        let refusal = { (problem: String) in MuterError.literal(reason: "Could not read \(path): \(problem)") }
        guard let text = String(data: data, encoding: .utf8) else { throw refusal("it isn't UTF-8") }
        let written: [Written.Entry]
        do {
            let document = try Yams.load(yaml: text)
            if let problem = unknownKey(in: document) { throw refusal(problem) }
            // An empty document, or one of comments alone, decodes as nothing, which Yams refuses.
            written = document == nil ? [] : try YAMLDecoder().decode(Written.self, from: text).mutants ?? []
        } catch let refused as MuterError {
            throw refused
        } catch {
            throw refusal("\(error)")
        }
        var seen: Set<MutantKey> = []
        return try written.map { entry in
            guard let mutant = MutantKey(wholeDescription: entry.mutant) else {
                throw refusal("\(entry.mutant) isn't a whole mutant key: give path:line:column Operator, as reports do")
            }
            guard let label = TriageLabel(rawValue: entry.label) else {
                throw refusal("\(mutant) has the label \(entry.label): give \(TriageLabel.listed)")
            }
            guard seen.insert(mutant).inserted else {
                throw refusal("\(mutant) has more than one label")
            }
            return TriageEntry(
                mutant: mutant,
                label: label,
                note: entry.note,
                before: entry.before,
                after: entry.after,
                line: entry.line
            )
        }
    }

    /// What's wrong with the first key in `document` that isn't one of the file's; nil when there's none.
    private static func unknownKey(in document: Any?) -> String? {
        guard let top = document as? [AnyHashable: Any] else { return nil }
        if let key = top.keys.map({ "\($0)" }).sorted().first(where: { $0 != "mutants" }) {
            return "\(key) isn't a key of this file: its labels are under mutants"
        }
        let known = ["mutant", "label", "note", "before", "after", "line"]
        for case let entry as [AnyHashable: Any] in top["mutants"] as? [Any] ?? [] {
            if let key = entry.keys.map({ "\($0)" }).sorted().first(where: { !known.contains($0) }) {
                return "\(key) isn't a key of a mutant's entry: give \(known.joined(separator: ", "))"
            }
        }
        return nil
    }

    /// Writes the entries, by path, line, column, operator and repeat, so a commit's diff shows only what changed.
    /// Comments in the file aren't kept. A file that's a symbolic link stays one, as the file it points to is written.
    func save(using fileManager: FileSystemManager) throws {
        let sorted = entries.sorted { lhs, rhs in
            let (left, right) = (lhs.mutant, rhs.mutant)
            return (left.path, left.line, left.column, left.mutationOperatorId.rawValue, left.occurrence)
                < (right.path, right.line, right.column, right.mutationOperatorId.rawValue, right.occurrence)
        }
        let text = try YAMLEncoder().encode(Saved(mutants: sorted))
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard fileManager.createFile(atPath: target, contents: Data(text.utf8), attributes: nil) else {
            throw MuterError.literal(reason: "SwiftMutator could not save \(path)")
        }
    }
}
