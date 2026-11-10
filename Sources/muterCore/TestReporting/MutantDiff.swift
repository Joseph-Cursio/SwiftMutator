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
            // A replaced Bool's or comparison's `false` is placed where it ends, on the line that holds it if it's on
            // one.
            let isOnItsOwnLine = isAConstant(snapshot, by: mutationOperatorId)
                || isALaterLinkOfATernaryChain(mutationOperatorId, at: column - 1, in: fileLines[line - 1])
            for number in stride(from: line, through: isOnItsOwnLine ? line : max(line - linesAbove, 1), by: -1) {
                let offsets = occurrences(of: needle, in: fileLines[number - 1])
                guard !offsets.isEmpty else { continue }
                guard offsets.count == 1 else { return nil }
                found = (number, offsets[0])
                break
            }
        }
        guard let found else { return nil }

        let text = fileLines[found.line - 1]
        let rest = text[(found.offset + needle.count)...]
        // `if(a)` becomes `if !((a))`, with a space the operator adds, as `if!(` doesn't parse; and `return(a < b)`
        // becomes `return true`, as a replaced Bool, comparison or return value is kept apart from a name or keyword
        // it would touch.
        let isKeptApart = isAConstant(snapshot, by: mutationOperatorId) || mutationOperatorId == .replaceReturnValue
        let isTouching = if mutationOperatorId == .negateConditional {
            text[..<found.offset].last.map { !Character(UnicodeScalar($0)).isWhitespace } == true
        } else {
            isKeptApart && text[..<found.offset].last.map(isPartOfAName) == true
        }
        let isTouchingAfter = isKeptApart && rest.first.map(isPartOfAName) == true
        let changed = Array(text[..<found.offset]) + (isTouching ? [UInt8(ascii: " ")] : [])
            + Array(replacement(snapshot, mutationOperatorId).utf8)
            + (isTouchingAfter ? [UInt8(ascii: " ")] : []) + Array(rest)
        let after = String(lossyUTF8: changed)
        return SourceChange(
            line: found.line,
            before: String(lossyUTF8: text),
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

    /// Whether the mutant replaces code with `true` or `false`, placed where that code starts for `true` and where it
    /// ends for `false`: a replaced Bool's, and a comparison's constant, whose `after` is a literal, where a swap's is
    /// an operator.
    static func isAConstant(_ snapshot: MutationOperator.Snapshot, by mutationOperatorId: MutationOperator.Id) -> Bool {
        isAConstant(after: snapshot.after, by: mutationOperatorId)
    }

    /// Whether a mutant of `mutationOperatorId` that puts `after` in place of its code replaces it with a constant
    /// (`isAConstant(_:by:)`).
    static func isAConstant(after: String, by mutationOperatorId: MutationOperator.Id) -> Bool {
        mutationOperatorId == .replaceBooleanValue || mutationOperatorId == .ror && ["true", "false"].contains(after)
    }

    /// Whether `byte` can be part of a name or a keyword, which a replaced value next to it would join.
    private static func isPartOfAName(_ byte: UInt8) -> Bool {
        let character = Character(UnicodeScalar(byte))
        return character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    /// Whether an operator's mutants are placed at the start of what they change, so a copy on a line above is never
    /// their own: a condition or a return value over several lines isn't found at its place, as `before` gives it on
    /// one line.
    private static func isPlacedWhereItsChangeStarts(_ mutationOperatorId: MutationOperator.Id) -> Bool {
        [.negateConditional, .flipBooleanLiteral, .arithmeticOperator, .replaceReturnValue]
            .contains(mutationOperatorId)
    }

    /// Whether a swapped ternary is placed at a `?`, as only a later link of a chain is. A first link is placed where
    /// its whole expression ends, which a `?` can't follow. A later link's `?` is inside what it changes, so a copy on
    /// a line above is never its own.
    private static func isALaterLinkOfATernaryChain(
        _ mutationOperatorId: MutationOperator.Id,
        at offset: Int,
        in line: [UInt8]
    ) -> Bool {
        mutationOperatorId == .swapTernary && line.indices.contains(offset) && line[offset] == UInt8(ascii: "?")
    }

    /// What the mutant puts in place of `snapshot.before`: nothing for a removed statement, whose snapshot says
    /// "removed line".
    static func replacement(
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
