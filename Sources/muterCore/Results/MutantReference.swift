import ArgumentParser
import Foundation

/// A mutant as a person names it: a place, `path:line[:column]`, then optionally its operator and its repeat, as
/// `MutantKey.description` prints a key. The path may be the end of the key's, down to the file name, as the progress
/// lines give it (`Bar.swift:12:9`), and the column may be left out, as the plain-text report does (`Bar.swift:12`).
/// What isn't given matches anything.
struct MutantReference: Hashable, CustomStringConvertible {
    /// As given, without a leading `./`: relative to the mutated project's root, the end of such a path, or absolute.
    let path: String
    let line: Int
    let column: Int?
    let mutationOperatorId: MutationOperator.Id?
    /// Which of the mutants at one place with one operator, counting from 0 as a key does: ` (#3)` gives 2. Nil when
    /// none is given.
    let occurrence: Int?

    init(
        path: String,
        line: Int,
        column: Int? = nil,
        mutationOperatorId: MutationOperator.Id? = nil,
        occurrence: Int? = nil
    ) {
        self.path = path
        self.line = line
        self.column = column
        self.mutationOperatorId = mutationOperatorId
        self.occurrence = occurrence
    }

    /// `path:line[:column]`, then ` Operator` and ` (#n)` when they were given: the text a key's description gives
    /// back exactly.
    var description: String {
        "\(path):\(line)"
            + (column.map { ":\($0)" } ?? "")
            + (mutationOperatorId.map { " \($0.rawValue)" } ?? "")
            + (occurrence.map { " (#\($0 + 1))" } ?? "")
    }

    /// The reference in `text`, read from its end, so that the path may hold spaces and colons. Around the text,
    /// spaces and line breaks are ignored.
    /// 1. A trailing ` (#n)`, with n 2 or more, is the repeat.
    /// 2. A last word of letters alone, after a space and a number, is the operator, which must be one SwiftMutator
    ///    has.
    /// 3. The last one or two `:` fields, whole numbers from 1, are the line and then the column.
    /// 4. The rest, which mustn't be empty, is the path, with any leading `./` dropped.
    static func parse(_ text: String) throws -> MutantReference {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))

        var occurrence: Int?
        if rest.hasSuffix(")"), let opening = rest.range(of: " (#", options: .backwards) {
            let digits = rest[opening.upperBound ..< rest.index(before: rest.endIndex)]
            guard let repeatNumber = wholeNumber(digits) else { throw usage }
            guard repeatNumber >= 2 else {
                throw ValidationError("give a repeat as (#2) or above; the first mutant at a place has no (#n).")
            }
            occurrence = repeatNumber - 1
            rest = trimmingTrailingSpaces(rest[..<opening.lowerBound])
        }

        var mutationOperatorId: MutationOperator.Id?
        if let space = rest.lastIndex(of: " "), trimmingTrailingSpaces(rest[..<space]).last?.isASCIIDigit == true {
            let word = rest[rest.index(after: space)...]
            if !word.isEmpty, word.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) {
                guard let id = MutationOperator.Id(rawValue: String(word)) else {
                    throw ValidationError("\(word) isn't an operator: give one of \(MutationOperator.Id.description).")
                }
                mutationOperatorId = id
                rest = trimmingTrailingSpaces(rest[..<space])
            }
        }

        var fields = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 2, let last = fields.popLast().flatMap(wholeNumber) else { throw usage }
        let line: Int
        var column: Int?
        if fields.count >= 2, let lineBeforeColumn = fields.last.flatMap(wholeNumber) {
            fields.removeLast()
            line = lineBeforeColumn
            column = last
        } else {
            line = last
        }
        guard line >= 1, column.map({ $0 >= 1 }) ?? true else { throw usage }

        var path = Substring(fields.joined(separator: ":"))
        while path.hasPrefix("./") {
            path = path.dropFirst(2)
        }
        guard !path.isEmpty else { throw usage }

        return MutantReference(
            path: String(path),
            line: line,
            column: column,
            mutationOperatorId: mutationOperatorId,
            occurrence: occurrence
        )
    }

    /// Whether `key` is this mutant, or one of the mutants this reference leaves open: its path and line match, and so
    /// do its column, operator and repeat where this reference gives them.
    func matches(_ key: MutantKey) -> Bool {
        matchesPath(key.path)
            && key.line == line
            && (column.map { $0 == key.column } ?? true)
            && (mutationOperatorId.map { $0 == key.mutationOperatorId } ?? true)
            && (occurrence.map { $0 == key.occurrence } ?? true)
    }

    /// Whether `keyPath`, a key's path, is this reference's or ends with it after a `/`: `Bar.swift` names
    /// `Sources/Foo/Bar.swift`, and `ar.swift` doesn't.
    func matchesPath(_ keyPath: String) -> Bool {
        keyPath == path || keyPath.hasSuffix("/" + path)
    }

    /// This reference with its path made relative to the first of `roots` it is inside, as a key's is, so that an
    /// absolute path in the project or in its copy matches the key; otherwise as it is. A path spelled through a
    /// symbolic link, as `/tmp` is `/private/tmp`, is inside a root when its folder, resolved, is inside the root,
    /// resolved: `getcwd()` gives the project's path resolved, and a shell's `$PWD` often doesn't. The file's own name
    /// isn't resolved, so a mutated file that is itself a link still names the link, as its key does.
    func relative(toFirstOf roots: [URL]) -> MutantReference {
        guard path.hasPrefix("/") else { return self }
        if let relative = Self.relative(path, toFirstOf: roots) {
            return with(path: relative)
        }
        let resolvedPath = (ProjectTree.resolved((path as NSString).deletingLastPathComponent) as NSString)
            .appendingPathComponent((path as NSString).lastPathComponent)
        let resolvedRoots = roots.map { URL(fileURLWithPath: ProjectTree.resolved($0.path)) }
        return Self.relative(resolvedPath, toFirstOf: resolvedRoots).map(with(path:)) ?? self
    }

    /// `path` relative to the first of `roots` it is inside, or nil when it is inside none.
    private static func relative(_ path: String, toFirstOf roots: [URL]) -> String? {
        roots.lazy
            .map { RepoRelativePath.of(path, under: $0) }
            .first { $0 != path }
    }

    /// This reference with `path` in place of its own.
    private func with(path: String) -> MutantReference {
        MutantReference(
            path: path,
            line: line,
            column: column,
            mutationOperatorId: mutationOperatorId,
            occurrence: occurrence
        )
    }

    private static let usage = ValidationError(
        "give the mutant as path:line[:column] [Operator], such as 'Sources/Foo/Bar.swift:12:9 SwapTernary'."
    )

    /// The number `digits` spell in ASCII digits alone, nil for anything else.
    private static func wholeNumber(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(digits)
    }

    private static func trimmingTrailingSpaces(_ text: Substring) -> Substring {
        var text = text
        while text.hasSuffix(" ") {
            text = text.dropLast()
        }
        return text
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
