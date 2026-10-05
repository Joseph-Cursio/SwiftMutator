import Foundation

/// What identifies a mutant across runs: where it is and what it does there. Never its position in the jobs, which
/// moving one file shifts for every later mutant, and not `MutationSchema.id`, which names the file only, so two
/// same-named files share it, and counts an offset into the file as SwiftMutator prepared it, which changes with any
/// edit above the mutant and with the header and import SwiftMutator inserts.
struct MutantKey: Hashable, Codable, CustomStringConvertible {
    /// Relative to the mutated project's root; absolute if outside it (`RepoRelativePath`).
    let path: String
    let mutationOperatorId: MutationOperator.Id
    /// The original file's line and column, which the header and import SwiftMutator inserts don't move.
    let line: Int
    let column: Int
    /// 0, or n for the nth repeat of the same place and operator in this run's jobs.
    let occurrence: Int

    var description: String {
        "\(path):\(line):\(column) \(mutationOperatorId.rawValue)" + (occurrence > 0 ? " (#\(occurrence + 1))" : "")
    }

    /// One key per schema, in order; a repeat of the same place and operator gets the next occurrence.
    static func keys(for schemata: [MutationSchema], under mutatedRoot: URL) -> [MutantKey] {
        var counts: [MutantKey: Int] = [:]
        return schemata.map { schema in
            let first = MutantKey(
                path: RepoRelativePath.of(schema.filePath, under: mutatedRoot),
                mutationOperatorId: schema.mutationOperatorId,
                line: schema.position.line,
                column: schema.position.column,
                occurrence: 0
            )
            let occurrence = counts[first, default: 0]
            counts[first] = occurrence + 1
            return MutantKey(
                path: first.path,
                mutationOperatorId: first.mutationOperatorId,
                line: first.line,
                column: first.column,
                occurrence: occurrence
            )
        }
    }
}

/// Paths in a results file: relative to the mutated project, so the results of a project that moved, or of the
/// same project on another Mac, still match. Exactly invertible for the absolute paths SwiftMutator discovers, so a
/// report rebuilt from the file shows the paths the run showed.
enum RepoRelativePath {
    /// `path` relative to `root`, or `path` as it is if it isn't inside `root`.
    static func of(_ path: String, under root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard path.hasPrefix(prefix) else { return path }
        let relative = path.dropFirst(prefix.count)
        // Empty, it is the root itself; starting with "/", resolving it would lose a slash.
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return path }
        return String(relative)
    }

    /// A path `of` gave, back under `root`: a relative one joined to it, an absolute one as it is.
    static func resolve(_ path: String, under root: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        return (root.hasSuffix("/") ? root : root + "/") + path
    }
}
