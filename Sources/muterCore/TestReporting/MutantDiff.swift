import Foundation

/// The lines that show what a mutant changes, which a run of one mutant (`--mutant`) prints.
enum MutantDiff {
    /// How many lines above its own a mutant's change is looked for: a mutant placed at the end of what it changes
    /// is on that code's last line.
    static let linesAbove = 5

    /// "-12:     return a ? b : c" and "+12:     return a ? c : b": `change`'s line before and after, which a run of
    /// one mutant prints. A removed statement's line has no `+` line if nothing but spaces is left of it. nil when
    /// `change` finds none.
    static func lines(
        original: String,
        snapshot: MutationOperator.Snapshot,
        mutationOperatorId: MutationOperator.Id,
        line: Int,
        column: Int
    ) -> [String]? {
        change(
            original: original,
            snapshot: snapshot,
            mutationOperatorId: mutationOperatorId,
            line: line,
            column: column
        )?.lines
    }

    /// The line of `original`, the original file's text, that holds the mutant's `snapshot.before`, and that line as
    /// the mutant changes it. The change is the one that starts at the mutant's column, as an operator's does, or else
    /// the only one on the nearest line, from the mutant's own up to `linesAbove` above it, unless `atItsPlaceOnly`:
    /// that line could be another, in a file that may have changed since. nil when there is no such change: a line
    /// that holds `before` more than once, or code that spans lines, which `before` gives on one line, or a file that
    /// isn't the one the mutant was found in.
    static func change(
        original: String,
        snapshot: MutationOperator.Snapshot,
        mutationOperatorId: MutationOperator.Id,
        line: Int,
        column: Int,
        atItsPlaceOnly: Bool = false
    ) -> SourceChange? {
        let needle = Array(snapshot.before.utf8)
        let fileLines = Array(original.utf8)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { $0.last == UInt8(ascii: "\r") ? Array($0.dropLast()) : Array($0) }
        guard !needle.isEmpty, line >= 1, line <= fileLines.count else { return nil }

        var found: (line: Int, offset: Int)?
        if occurrences(of: needle, in: fileLines[line - 1]).contains(column - 1) {
            found = (line, column - 1)
        } else if !atItsPlaceOnly, !isPlacedWhereItsChangeStarts(mutationOperatorId) {
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
        // `if(a)` becomes `if !((a))`, with a space the operator adds, as `if!(` doesn't parse.
        let isTouching = mutationOperatorId == .negateConditional
            && text[..<found.offset].last.map { !Character(UnicodeScalar($0)).isWhitespace } == true
        let changed = Array(text[..<found.offset]) + (isTouching ? [UInt8(ascii: " ")] : [])
            + Array(replacement(snapshot, mutationOperatorId).utf8)
            + Array(text[(found.offset + needle.count)...])
        let after = String(decoding: changed, as: UTF8.self)
        return SourceChange(
            line: found.line,
            before: String(decoding: text, as: UTF8.self),
            after: after.trimmingCharacters(in: .whitespaces).isEmpty ? nil : after
        )
    }

    /// "- a ? b : c" and "+ a ? c : b": the change as the mutant's snapshot gives it, on one line each, for when
    /// `lines` finds none. A removed statement has no `+` line.
    static func fallback(snapshot: MutationOperator.Snapshot, mutationOperatorId: MutationOperator.Id) -> [String] {
        let before = "- " + snapshot.before
        let after = replacement(snapshot, mutationOperatorId)
        return after.isEmpty ? [before] : [before, "+ " + after]
    }

    /// Whether an operator's mutants are placed at the start of what they change, so a copy on a line above is never
    /// their own: a condition over several lines isn't found at its place, as `before` gives it on one line.
    private static func isPlacedWhereItsChangeStarts(_ mutationOperatorId: MutationOperator.Id) -> Bool {
        mutationOperatorId == .negateConditional
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

/// The line a mutant changes, as its original file holds it and as the mutant makes it (`MutantDiff.change`). The
/// JSON report holds it as `{line, before, after?}`.
struct SourceChange: Codable, Equatable {
    /// From 1.
    let line: Int
    let before: String
    /// nil for a removed statement that leaves nothing but spaces on its line.
    let after: String?

    /// "-12:     return a ? b : c" and "+12:     return a ? c : b"; a line removed whole has no `+` line.
    var lines: [String] {
        ["-\(line): \(before)"] + (after.map { ["+\(line): \($0)"] } ?? [])
    }
}
