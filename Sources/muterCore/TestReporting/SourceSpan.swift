import Foundation

/// Where a mutant's code is in its original file, from its first character to just past its last, as the Stryker and
/// SARIF reports give it: lines and columns from 1, columns in UTF-16 code units. Stryker's viewer is JavaScript,
/// whose strings count those, and they are SARIF's default. SwiftSyntax counts columns in UTF-8 bytes
/// (`MutationPosition`), so an `é` before the mutant is two of its columns but one here, and an emoji four but two.
struct SourceSpan: Equatable {
    struct Position: Equatable {
        let line: Int
        let column: Int
    }

    let start: Position
    /// Just past the last character, as both formats want it.
    let end: Position

    init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }

    /// The span of the code `mutation` changes, its `before`, in its original file, whose lines are `lines`, and
    /// whether that code was found there (`SourceLines.span(of:placedAt:utf8Column:by:)`). Code not found where its
    /// operator places it, as in a file changed since, spans the mutant's whole line. Without that line, as for a file
    /// that can't be read, the columns stay in bytes, and the span is `before` from the mutant's place, or up to it for
    /// an operator that places a mutant where its code ends.
    static func of(_ mutation: MutationTestOutcome.Mutation, in lines: SourceLines?) -> (span: Self, isFound: Bool) {
        let position = mutation.point.position
        let operatorId = mutation.point.mutationOperatorId
        let before = mutation.snapshot.before
        let after = mutation.snapshot.after
        if let found = lines?.span(
            of: before,
            placedAt: position.line,
            utf8Column: position.column,
            by: operatorId,
            after: after
        ) {
            return (found, true)
        }
        if let line = lines?.span(ofLine: position.line) {
            return (line, false)
        }
        return (
            Self(placedAt: position.line, utf8Column: position.column, before: before, by: operatorId, after: after),
            false
        )
    }

    /// `before` from the UTF-8 `column` of `line`, in bytes, or up to it for a mutant placed where its code ends, as
    /// `after` tells for a replaced Bool's and a comparison's constant; `before` may span lines.
    init(
        placedAt line: Int,
        utf8Column column: Int,
        before: String,
        by operatorId: MutationOperator.Id,
        after: String = ""
    ) {
        let isAConstant = MutantDiff.isAConstant(after: after, by: operatorId)
        let parts = SourceLines.split(isAConstant ? before : SourceLines.code(of: before, by: operatorId))
        let last = parts.last ?? ""
        let endsThere = SourceLines.isPlacedWhereItsCodeEnds(operatorId) || isAConstant && after == "false"
        if endsThere, parts.count == 1 {
            let spanStart = Position(line: line, column: max(1, column - last.utf8.count))
            self.init(start: spanStart, end: Position(line: line, column: column))
            return
        }
        let spanStart = Position(line: line, column: column)
        self.init(start: spanStart, end: parts.count == 1
            ? Position(line: line, column: column + last.utf8.count)
            : Position(line: line + parts.count - 1, column: 1 + last.utf8.count))
    }
}

/// A file's text by line, as the reports read it: each line without its line break, which is `\n`, `\r\n` or a lone
/// `\r`, as SwiftSyntax numbers lines.
struct SourceLines {
    private let lines: [String]
    /// The text in UTF-8, with each line break one `\n`, and where each line starts in it.
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ text: String) {
        lines = Self.split(text)
        bytes = Array(lines.joined(separator: "\n").utf8)
        var starts: [Int] = []
        var next = 0
        for line in lines {
            starts.append(next)
            next += line.utf8.count + 1
        }
        lineStarts = starts
    }

    /// How many lines the file has: one more than its line breaks.
    var count: Int {
        lines.count
    }

    /// Line `number`, from 1; nil past the end.
    func line(_ number: Int) -> String? {
        lines.indices.contains(number - 1) ? lines[number - 1] : nil
    }

    /// `text`'s lines, split by scalar, as `\r\n` is one `Character`, at each line break SwiftSyntax counts: `\n`,
    /// `\r\n` and a lone `\r`. So a `\r\r\n` is two, and a mutant's line is the one it numbers.
    static func split(_ text: String) -> [String] {
        var fileLines: [String] = []
        var line = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in text.unicodeScalars {
            defer { afterReturn = scalar == "\r" }
            guard scalar != "\n" || !afterReturn else { continue }
            if scalar == "\n" || scalar == "\r" {
                fileLines.append(String(line))
                line = String.UnicodeScalarView()
            } else {
                line.append(scalar)
            }
        }
        fileLines.append(String(line))
        return fileLines
    }

    /// The UTF-16 column of the character at the UTF-8 `column` of line `number`; nil when there is no such line. A
    /// column inside a character, which a file changed since may give, counts the part before it as one unit; one past
    /// the line's end counts each byte past it as one.
    func utf16Column(ofUTF8Column column: Int, onLine number: Int) -> Int? {
        guard lines.indices.contains(number - 1), column >= 1 else { return nil }
        let lineBytes = Array(lines[number - 1].utf8)
        let offset = column - 1
        let before = String(decoding: lineBytes.prefix(offset), as: UTF8.self)
        return before.utf16.count + max(0, offset - lineBytes.count) + 1
    }

    /// Line `number` whole, from its first column to just past its last; nil when there is no such line.
    func span(ofLine number: Int) -> SourceSpan? {
        line(number).map { line in
            SourceSpan(start: .init(line: number, column: 1), end: .init(line: number, column: line.utf16.count + 1))
        }
    }

    /// The text `span` covers, its lines joined by `\n`; nil when the file has no such lines.
    func text(of span: SourceSpan) -> String? {
        guard span.start.line <= span.end.line,
              let first = line(span.start.line).map({ Array($0.utf16) }),
              let last = line(span.end.line).map({ Array($0.utf16) })
        else { return nil }
        let from = min(max(span.start.column - 1, 0), first.count)
        let upTo = min(max(span.end.column - 1, 0), last.count)
        guard span.start.line < span.end.line else {
            return String(decoding: first[from..<max(from, upTo)], as: UTF16.self)
        }
        let middle = (span.start.line + 1..<span.end.line).compactMap(line)
        return ([String(decoding: first[from...], as: UTF16.self)] + middle
            + [String(decoding: last[..<upTo], as: UTF16.self)]).joined(separator: "\n")
    }

    /// Where `before`, the code a mutant of `operatorId` changes, is in the file, given the place its operator
    /// recorded, the UTF-8 `column` of `line`; nil when it isn't there. An operator's place isn't always where its code
    /// starts. Most place a mutant at its start, but before a line break that starts its line, as `&&` that starts one
    /// is placed at the end of the line above. Removing a statement and swapping a ternary place it where the code
    /// ends, but for a later link of a ternary chain, which is placed at its `?`. A replaced Bool's `true` is placed
    /// where its value starts and its `false` where it ends, and so is a comparison's constant, as `after` tells, so
    /// its code is looked for before the place, then after it: what comes just before a value, a keyword, a `=` or a
    /// brace, can't end as the value does. And `before` gives code over several lines on one, its line breaks and
    /// indents as one space each, so any spaces in it match any in the file. The comparison and logical operators'
    /// swaps are placed before any comment beside their token, and their `before` holds it, but the mutant changes
    /// the token alone, so that is the code found (`code(of:by:)`).
    func span(
        of before: String,
        placedAt line: Int,
        utf8Column column: Int,
        by operatorId: MutationOperator.Id,
        after: String = ""
    ) -> SourceSpan? {
        let isAConstant = MutantDiff.isAConstant(after: after, by: operatorId)
        let code = Array((isAConstant ? before : Self.code(of: before, by: operatorId)).utf8)
        guard !code.isEmpty, lines.indices.contains(line - 1), column >= 1 else { return nil }
        let place = lineStarts[line - 1] + min(column - 1, lines[line - 1].utf8.count)
        let found: Range<Int>?
        if operatorId == .swapTernary, bytes.indices.contains(place), bytes[place] == UInt8(ascii: "?") {
            let earliest = lineStarts[max(line - MutantDiff.linesAbove, 1) - 1]
            found = stride(from: place, through: earliest, by: -1).lazy.compactMap { start in
                match(code, from: start, forward: true).flatMap { $0 > place ? start..<$0 : nil }
            }.first
        } else if Self.isPlacedWhereItsCodeEnds(operatorId) {
            let end = skipping(from: place, forward: false)
            found = match(code, from: end, forward: false).map { $0..<end }
        } else if isAConstant {
            let end = skipping(from: place, forward: false)
            let start = skipping(from: place, forward: true)
            found = match(code, from: end, forward: false).map { $0..<end }
                ?? match(code, from: start, forward: true).map { start..<$0 }
        } else {
            let start = skipping(from: place, forward: true, comments: Self.keepsCommentsBeside(operatorId))
            found = match(code, from: start, forward: true).map { start..<$0 }
        }
        return found.map { range in
            SourceSpan(start: position(ofOffset: range.lowerBound), end: position(ofOffset: range.upperBound))
        }
    }

    /// Whether an operator places a mutant where its code ends: a ternary's first link does, a later one doesn't.
    static func isPlacedWhereItsCodeEnds(_ operatorId: MutationOperator.Id) -> Bool {
        [.removeSideEffects, .swapTernary].contains(operatorId)
    }

    /// The code of `before` that a span is found for. The comparison and logical operators' `before` is their
    /// token's node, with any comment beside the token (`TokenAwareVisitor`), and their tokens hold no `/`, so it is
    /// that without its comments. Any other's is `before` itself.
    static func code(of before: String, by operatorId: MutationOperator.Id) -> String {
        guard keepsCommentsBeside(operatorId) else { return before }
        var beforeBytes = Array(before.utf8)
        var index = 0
        while index < beforeBytes.count {
            let width = commentWidth(beforeBytes, at: index)
            beforeBytes.replaceSubrange(index..<index + width, with: width > 0 ? [UInt8(ascii: " ")] : [])
            index += 1
        }
        return String(decoding: beforeBytes, as: UTF8.self).trimmed
    }

    /// Whether an operator's `before` keeps the comments beside its token, and places its mutant before them.
    private static func keepsCommentsBeside(_ operatorId: MutationOperator.Id) -> Bool {
        [.ror, .relationalBoundary, .logicalOperator].contains(operatorId)
    }

    /// Where `code` ends in the text when it starts at `offset`, reading forward, or where it starts when it ends
    /// there, reading back; nil when it isn't there. Each run of spaces in `code` matches a run in the text.
    private func match(_ code: [UInt8], from offset: Int, forward: Bool) -> Int? {
        let step = forward ? 1 : -1
        var index = forward ? 0 : code.count - 1
        var next = forward ? offset : offset - 1
        while code.indices.contains(index) {
            if Self.spaceWidth(code, at: index, forward: forward) > 0 {
                guard Self.spaceWidth(bytes, at: next, forward: forward) > 0 else { return nil }
                index = Self.skipping(code, from: index, forward: forward)
                next = Self.skipping(bytes, from: next, forward: forward)
            } else {
                guard bytes.indices.contains(next), bytes[next] == code[index] else { return nil }
                index += step
                next += step
            }
        }
        return forward ? next : next + 1
    }

    /// Where the text's spaces, and its comments if asked, end from `offset`, reading forward, or start when they end
    /// there, reading back.
    private func skipping(from offset: Int, forward: Bool, comments: Bool = false) -> Int {
        guard forward else { return Self.skipping(bytes, from: offset - 1, forward: false) + 1 }
        var next = offset
        while case let width = Self.spaceWidth(bytes, at: next, forward: true)
            + (comments ? Self.commentWidth(bytes, at: next) : 0), width > 0 {
            next += width
        }
        return next
    }

    /// The index past the spaces in `bytes` from `index`, reading forward, or before them, reading back.
    private static func skipping(_ bytes: [UInt8], from index: Int, forward: Bool) -> Int {
        var next = index
        while case let width = spaceWidth(bytes, at: next, forward: forward), width > 0 {
            next += forward ? width : -width
        }
        return next
    }

    /// The line and UTF-16 column of the byte at `offset` of the text.
    private func position(ofOffset offset: Int) -> SourceSpan.Position {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let column = offset - lineStarts[low] + 1
        return SourceSpan.Position(line: low + 1, column: utf16Column(ofUTF8Column: column, onLine: low + 1) ?? column)
    }

    /// How many bytes the space at `index` of `bytes` takes, from its first byte reading forward, or from its last
    /// reading back; 0 when there is none. A space is any that `trimmed` and `inlined` take out of `before`, as the
    /// no-break space and the line separator, not only those in ASCII, so that the file's match `before`'s.
    private static func spaceWidth(_ bytes: [UInt8], at index: Int, forward: Bool) -> Int {
        guard bytes.indices.contains(index) else { return 0 }
        guard bytes[index] >= 0x80 else {
            return [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"), 0x0B, 0x0C]
                .contains(bytes[index]) ? 1 : 0
        }
        var start = index
        while !forward, start > max(0, index - 3), bytes[start] & 0xC0 == 0x80 {
            start -= 1
        }
        let lead = bytes[start]
        let width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        guard start + width <= bytes.count, forward || start + width - 1 == index else { return 0 }
        let scalars = String(decoding: bytes[start..<start + width], as: UTF8.self).unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first, CharacterSet.whitespacesAndNewlines.contains(scalar)
        else { return 0 }
        return width
    }

    /// How many bytes the comment that starts at `index` of `bytes` takes: a `//` one up to its line break, a `/*`
    /// one through its `*/`, counting those nested in it; 0 when none starts there.
    private static func commentWidth(_ bytes: [UInt8], at index: Int) -> Int {
        let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        guard index + 1 < bytes.count, bytes[index] == slash, [slash, star].contains(bytes[index + 1]) else { return 0 }
        var next = index + 2
        if bytes[index + 1] == slash {
            while next < bytes.count, ![UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(bytes[next]) {
                next += 1
            }
            return next - index
        }
        var depth = 1
        while next < bytes.count, depth > 0 {
            let pair = next + 1 < bytes.count ? (bytes[next], bytes[next + 1]) : (bytes[next], 0)
            if pair == (slash, star) || pair == (star, slash) {
                depth += pair.0 == slash ? 1 : -1
                next += 2
            } else {
                next += 1
            }
        }
        return next - index
    }
}

/// The original files a report reads, each once, by path: the Stryker report embeds them, and both it and SARIF take
/// each mutant's columns from them.
struct OriginalFiles {
    private let contents: [String: Data]

    /// Reads each of `paths` with `read`, as the other reports read theirs (`readSourceFile`).
    init(_ paths: some Sequence<String>, read: ReadFile) {
        var fileContents: [String: Data] = [:]
        for path in Set(paths) {
            fileContents[path] = read(path)
        }
        self.contents = fileContents
    }

    /// The file at `path` as text, with a byte that isn't UTF-8 as U+FFFD; nil when it couldn't be read.
    func text(at path: String) -> String? {
        contents[path].map { String(decoding: $0, as: UTF8.self) }
    }

    /// Reads a file from those already read, so `ReportSources` doesn't read it again.
    var read: ReadFile {
        { [contents] path in contents[path] }
    }
}
