import Foundation

/// The lines that show what a mutant changes, which a run of one mutant (`--mutant`) prints.
enum MutantDiff {
    /// How many lines above its own a mutant's change is looked for: a mutant placed at the end of what it changes
    /// is on that code's last line.
    static let linesAbove = 5

    /// "-12:     return a ? b : c" and "+12:     return a ? c : b": the line of `original`, the original file's text,
    /// that holds the mutant's `snapshot.before`, and that line as the mutant changes it. A removed statement's line
    /// has no `+` line if nothing but spaces is left of it. The change is the one that starts at the mutant's column,
    /// as an operator's does, or else the only one on the nearest line, from the mutant's own up to `linesAbove` above
    /// it. nil when there is no such change: a line that holds `before` more than once, or code that spans lines,
    /// which `before` gives on one line, or a file that isn't the one the mutant was found in.
    static func lines(
        original: String,
        snapshot: MutationOperator.Snapshot,
        mutationOperatorId: MutationOperator.Id,
        line: Int,
        column: Int
    ) -> [String]? {
        let needle = Array(snapshot.before.utf8)
        let fileLines = Array(original.utf8)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { $0.last == UInt8(ascii: "\r") ? Array($0.dropLast()) : Array($0) }
        guard !needle.isEmpty, line >= 1, line <= fileLines.count else { return nil }

        var found: (line: Int, offset: Int)?
        if occurrences(of: needle, in: fileLines[line - 1]).contains(column - 1) {
            found = (line, column - 1)
        } else {
            for number in stride(from: line, through: max(line - linesAbove, 1), by: -1) {
                let offsets = occurrences(of: needle, in: fileLines[number - 1])
                guard !offsets.isEmpty else { continue }
                guard offsets.count == 1 else { return nil }
                found = (number, offsets[0])
                break
            }
        }
        guard let found else { return nil }

        let text = fileLines[found.line - 1]
        let changed = Array(text[..<found.offset]) + Array(replacement(snapshot, mutationOperatorId).utf8)
            + Array(text[(found.offset + needle.count)...])
        let before = "-\(found.line): " + String(decoding: text, as: UTF8.self)
        let after = String(decoding: changed, as: UTF8.self)
        guard !after.trimmingCharacters(in: .whitespaces).isEmpty else { return [before] }
        return [before, "+\(found.line): " + after]
    }

    /// "- a ? b : c" and "+ a ? c : b": the change as the mutant's snapshot gives it, on one line each, for when
    /// `lines` finds none. A removed statement has no `+` line.
    static func fallback(snapshot: MutationOperator.Snapshot, mutationOperatorId: MutationOperator.Id) -> [String] {
        let before = "- " + snapshot.before
        let after = replacement(snapshot, mutationOperatorId)
        return after.isEmpty ? [before] : [before, "+ " + after]
    }

    /// What the mutant puts in place of `snapshot.before`: nothing for a removed statement, whose snapshot says
    /// "removed line".
    private static func replacement(
        _ snapshot: MutationOperator.Snapshot,
        _ mutationOperatorId: MutationOperator.Id
    ) -> String {
        mutationOperatorId == .removeSideEffects ? "" : snapshot.after
    }

    /// Where each copy of `needle` starts in `line`, by its UTF-8 offset.
    private static func occurrences(of needle: [UInt8], in line: [UInt8]) -> [Int] {
        guard line.count >= needle.count else { return [] }
        return (0...(line.count - needle.count)).filter { start in
            line[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}
