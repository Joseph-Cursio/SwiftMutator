import Foundation

/// Text made safe to put in Markdown, as GitHub renders it: paths, test names, triage notes and mutants' descriptions
/// can hold any character, and one that Markdown reads as formatting would change or hide what they say.
enum MarkdownText {
    /// The characters that start or end formatting anywhere in a line: emphasis, code, links, HTML, tables,
    /// strikethrough, entities and GitHub's math. Each is escaped with a backslash, which Markdown takes for any
    /// punctuation. Those that mean something only at the start of a line never start one here.
    private static let punctuation: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "|", "~", "&", "$"]

    /// `text` as plain text, on one line: each of `punctuation` escaped, so it reads as written, and each line break
    /// a space, as a line of its own could start a list or a heading. Safe in a table's cell too, whose `|` it escapes.
    static func plain(_ text: String) -> String {
        String(oneLine(text).flatMap { character -> [Character] in
            punctuation.contains(character) ? ["\\", character] : [character]
        })
    }

    /// `text` as a code span, on one line: fenced with one more backtick than its longest run of them, so none ends
    /// it, and padded with a space where it starts or ends with a backtick, or with a space on both sides, which the
    /// fence would otherwise take. Nothing is escaped within it, as Markdown escapes nothing in code.
    static func code(_ text: String) -> String {
        let flattened = oneLine(text)
        guard !flattened.isEmpty else { return "" }
        var longest = 0
        var run = 0
        for character in flattened {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padded = flattened.first == "`" || flattened.last == "`" || (flattened.first == " " && flattened.last == " ")
        let pad = padded ? " " : ""
        return fence + pad + flattened + pad + fence
    }

    /// `text` as a code span in a table's cell, whose `|` would end the cell even within code: GitHub reads `\|`
    /// there as a `|`.
    static func codeInCell(_ text: String) -> String {
        code(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// A table with `header`'s cells, each of `rows`, and each column aligned as `alignments` says: true to the
    /// right, for numbers. Each cell is already made safe.
    static func table(header: [String], alignments: [Bool], rows: [[String]]) -> String {
        let line = { (cells: [String]) in "| " + cells.joined(separator: " | ") + " |" }
        let rule = "|" + alignments.map { $0 ? " ---: |" : " :--- |" }.joined()
        return ([line(header), rule] + rows.map(line)).joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
    }
}
