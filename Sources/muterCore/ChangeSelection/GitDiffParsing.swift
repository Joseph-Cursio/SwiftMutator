import Foundation

/// Reads what `git diff` prints, as `GitChanges` asks for it.
enum GitDiffParsing {
    /// A file in `git diff --name-status -z`: how it changed, and its path, with the path it had at the merge base if
    /// it was renamed.
    struct Entry: Equatable {
        enum Status: Equatable {
            case added
            case modified
            case renamed(from: String)
            case deleted
            /// A type change, such as a file that became a symbolic link, or a conflict: no line of it is known to be
            /// the merge base's.
            case replaced
        }

        let status: Status
        let path: String
    }

    /// The entries of `git diff --name-status -z` output: each a status, a score after it for a rename or a copy, and
    /// one path, or two for a rename or a copy, each ended by a NUL. A copy, which `--find-renames` alone never
    /// reports, is an added file. An unknown status ends the reading, as its paths can't be told apart.
    static func entries(ofNameStatus output: String) -> [Entry] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        var entries: [Entry] = []
        while let status = fields.popFirst(), !status.isEmpty {
            switch status.first {
            case "A"?, "M"?, "D"?, "T"?, "U"?:
                guard let path = fields.popFirst() else { return entries }
                let kinds: [Character: Entry.Status] = [
                    "A": .added, "M": .modified, "D": .deleted, "T": .replaced, "U": .replaced,
                ]
                entries.append(Entry(status: status.first.flatMap { kinds[$0] } ?? .replaced, path: path))
            case "R"?, "C"?:
                guard let old = fields.popFirst(), let new = fields.popFirst() else { return entries }
                entries.append(Entry(status: status.first == "R" ? .renamed(from: old) : .added, path: new))
            default:
                return entries
            }
        }
        return entries
    }

    /// The new side's lines that `git diff -U0` output's hunks add or change, and the lines after which they only
    /// remove some. A hunk header `@@ -a,b +c,d @@` adds or changes lines c to c + d - 1; `d` is 1 when left out, and
    /// with `d` 0 the hunk only removes lines, after line c, which is 0 at the start of the file.
    static func hunks(ofUnifiedDiff output: String) -> (lines: [LineRange], deletionsAfter: [Int]) {
        var lines: [LineRange] = []
        var deletionsAfter: [Int] = []
        // By line feed, not by Character: a line of code that ends in a carriage return makes "\r\n" one Character,
        // which would join the next hunk's header to it.
        for line in output.components(separatedBy: "\n") where line.hasPrefix("@@ ") {
            guard let newSide = line.split(separator: " ").dropFirst(2).first, newSide.hasPrefix("+") else { continue }
            let numbers = newSide.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = numbers.first.flatMap({ Int($0) }) else { continue }
            let count = numbers.count > 1 ? Int(numbers[1]) : 1
            guard let count else { continue }
            if count == 0 {
                deletionsAfter.append(start)
            } else {
                lines.append(LineRange(first: start, last: start + count - 1))
            }
        }
        return (lines, deletionsAfter)
    }
}
