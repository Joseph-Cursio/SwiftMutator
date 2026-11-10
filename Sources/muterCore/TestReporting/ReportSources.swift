import Foundation

/// The original files the reports show mutants' lines from, each read once, and none that has changed since it was
/// tested: a mutant's line is found by its place, which an edit since would move.
struct ReportSources {
    private let read: ReadFile
    /// Each file's SHA-256 as it was tested, by its path relative to the project; nil when not recorded. A file whose
    /// hash isn't known, as one the tree doesn't hold or records as a symbolic link (`ProjectTree.linkPrefix`), may be
    /// as it was: its change is taken only where it starts at the mutant's place.
    private let digests: [String: String]?
    private var texts: [String: (text: String, verified: Bool)?] = [:]

    init(read: @escaping ReadFile, digests: [String: String]?) {
        self.read = read
        self.digests = digests
    }

    /// The line `mutation` changes, before and after; nil when its file can't be read, has changed since it was
    /// tested, or doesn't hold the change on one line.
    mutating func change(of mutation: MutationTestOutcome.Mutation) -> SourceChange? {
        change(
            in: mutation.originalProjectPath,
            relativePath: mutation.relativePath,
            snapshot: mutation.snapshot,
            mutationOperatorId: mutation.point.mutationOperatorId,
            at: mutation.point.position
        )
    }

    /// The line a mutant changes, before and after, that replaces `snapshot` at the line and column of `position` in
    /// the original file at `path`, `relativePath` in the project; nil as for `change(of:)`.
    mutating func change(
        in path: String,
        relativePath: String,
        snapshot: MutationOperator.Snapshot,
        mutationOperatorId: MutationOperator.Id,
        at position: MutationPosition
    ) -> SourceChange? {
        guard let source = text(at: path, relativePath: relativePath) else { return nil }
        return MutantDiff.change(
            original: source.text,
            snapshot: snapshot,
            mutationOperatorId: mutationOperatorId,
            line: position.line,
            column: position.column,
            atItsPlaceOnly: !source.verified
        )
    }

    /// Whether the original file at `path`, `relativePath` in the project, can be read, as it was tested: a change
    /// it doesn't find there isn't on one line.
    mutating func reads(_ path: String, relativePath: String) -> Bool {
        text(at: path, relativePath: relativePath) != nil
    }

    /// The text of the original file at `path`, `relativePath` in the project, and whether its hash is the one
    /// recorded; nil when it can't be read, isn't UTF-8, or has another hash than the one recorded.
    private mutating func text(at path: String, relativePath: String) -> (text: String, verified: Bool)? {
        if let source = texts[path] {
            return source
        }
        let source = read(path).flatMap { data -> (text: String, verified: Bool)? in
            let recorded = (digests?[relativePath]
                ?? digests?[relativePath.precomposedStringWithCanonicalMapping])
                .flatMap { $0.hasPrefix(ProjectTree.linkPrefix) ? nil : $0 }
            if let recorded, recorded != FileDigest.sha256(of: data) {
                return nil
            }
            return String(data: data, encoding: .utf8).map { ($0, recorded != nil) }
        }
        texts[path] = .some(source)
        return source
    }
}
