import Foundation

/// What `--since` chose: the Swift files changed since the merge base of a ref and HEAD, in the working tree, as the
/// project's copy holds them; and with `--changed-lines`, their changed lines. Recorded in the results file's header,
/// and compared when a run is resumed.
struct ChangeSelection: Codable, Equatable, Sendable {
    /// As given.
    let ref: String
    /// The commit `ref` names.
    let commit: String
    /// The merge base of `commit` and HEAD, which the working tree is compared with.
    let mergeBase: String
    /// `--changed-lines`: only the mutants on a line the change added or changed are tested.
    let changedLines: Bool
    /// The Swift files that changed, by their paths in the project, sorted, before the excludes and the coverage
    /// filter: a removed file isn't one.
    let files: [ChangedFile]
    /// The project's folders that are repositories of their own, submodules or not, whose changes aren't compared:
    /// none of their files is chosen. Absent when there are none.
    let foldersNotCompared: [String]?

    init(
        ref: String,
        commit: String,
        mergeBase: String,
        changedLines: Bool,
        files: [ChangedFile],
        foldersNotCompared: [String] = []
    ) {
        self.ref = ref
        self.commit = commit
        self.mergeBase = mergeBase
        self.changedLines = changedLines
        self.files = files
        self.foldersNotCompared = foldersNotCompared.isEmpty ? nil : foldersNotCompared
    }

    /// The same choice, from `ref`, which named `commit`: a resumed session's, whose command names the merge base,
    /// keeps the first one's.
    func named(_ ref: String, commit: String) -> ChangeSelection {
        ChangeSelection(
            ref: ref,
            commit: commit,
            mergeBase: mergeBase,
            changedLines: changedLines,
            files: files,
            foldersNotCompared: foldersNotCompared ?? []
        )
    }

    /// The changed file at `path` in the project, if it is one.
    func file(at path: String) -> ChangedFile? {
        let normalized = path.precomposedStringWithCanonicalMapping
        return files.first { $0.path == normalized }
    }

    /// `mergeBase`'s first 7 characters, as git abbreviates a commit.
    var shortMergeBase: String {
        String(mergeBase.prefix(7))
    }

    /// The ref as said: abbreviated when it is the merge base itself, as a resumed session's command gives it.
    var shownRef: String {
        ref == mergeBase ? shortMergeBase : ref
    }
}

/// A Swift file that changed since the merge base.
struct ChangedFile: Codable, Equatable, Sendable {
    /// Its path in the project, as the disk spells it, precomposed (NFC).
    let path: String
    /// Only with `--changed-lines`: the lines, in the working tree, that the change added or changed. nil when the
    /// whole file is new to the change: added since the merge base, not yet known to git, or of another type then.
    let lines: [LineRange]?
    /// Only with `--changed-lines`: each line after which the change only removed lines; 0 is the file's start.
    let deletionsAfter: [Int]?
    /// The file's SHA-256 when it was compared with the merge base, which the copy's must equal.
    let sha256: String

    init(path: String, lines: [LineRange]? = nil, deletionsAfter: [Int]? = nil, sha256: String) {
        self.path = path
        self.lines = lines
        self.deletionsAfter = deletionsAfter
        self.sha256 = sha256
    }

    /// Whether code on the lines `span` was changed: any of them was added or changed, or lines were removed between
    /// two of them, as from the middle of a statement. A whole file that is new to the change holds only changed code.
    func isChanged(_ span: ClosedRange<Int>) -> Bool {
        guard let lines else { return true }
        return lines.contains { $0.first <= span.upperBound && span.lowerBound <= $0.last }
            || (deletionsAfter ?? []).contains { span.lowerBound <= $0 && $0 + 1 <= span.upperBound }
    }
}

/// Lines `first` through `last`, counted from 1; written as `[first, last]`.
struct LineRange: Codable, Equatable, Sendable {
    let first: Int
    let last: Int

    init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(Int.self)
        last = try container.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(first)
        try container.encode(last)
    }
}
