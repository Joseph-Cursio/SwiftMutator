import ArgumentParser
import Foundation

extension MergedShards {
    /// What `report` says on standard error of the merge: how many mutants it covers, each shard's file and how its run
    /// ended and which of its sessions tested its results, the shards whose files weren't given, and what may make the
    /// report differ from a whole run's. One shard's file alone is said as any other file is, naming its shard.
    func statusLines() -> [String] {
        let count = reference.shard.count
        var lines = parts.count == 1 ? onlyShardLines(count: count) : shardLines(count: count)
        lines += absentShardLines(count: count)
        if !discoveriesAgree {
            let found = parts.enumerated().map { offset, part in
                let mutants = offset == 0 ? "discovered \(Self.mutants(part.selection.mutantsInAllShards)) in all"
                    : "\(part.selection.mutantsInAllShards)"
                return "shard \(part.shard.index) of \(count)'s \(mutants)"
            }
            lines.append(
                "The shards' runs didn't discover the same mutants: \(Logger.listed(found)), so a mutant that some "
                    + "of them didn't discover may have no result."
            )
        }
        if !forced.isEmpty {
            let subjects = forced.map { name in
                let subject = ResumeCheck.subject(of: name)
                return subject.hasPrefix("The ") ? "the " + subject.dropFirst(4) : subject
            }
            let differ = subjects.count == 1 ? "differs" : "differ"
            lines.append("Merged although \(Logger.listed(subjects)) \(differ) between the shards (--force-merge).")
        }
        if !waived.isEmpty {
            let named = waived.prefix(ResumeRefusal.changedFilesNamed)
            let others = waived.count - named.count
            let files = waived.count == 1 ? "1 project file differs" : "\(waived.count) project files differ"
            lines.append(
                "Merged although \(files) between the shards (--merge-ignoring): "
                    + named.joined(separator: ", ") + (others > 0 ? ", and \(others) more." : ".")
            )
        }
        for part in parts where part.recorded.headers.contains(where: Self.letChangesThrough) {
            lines.append(
                "Shard \(part.shard.index) of \(count) kept results although changes were let through when it was "
                    + "resumed or reused: its headers' forced and waived say which."
            )
        }
        return lines
    }

    /// The lines of a report of one shard's file alone: how many of its mutants it covers, from where, and how its
    /// run ended, then which of its sessions tested its results.
    private func onlyShardLines(count: Int) -> [String] {
        let only = reference
        var lines = [
            "Report of \(only.recorded.latest.count) of \(Self.mutants(only.header.mutantsDiscovered)) in shard "
                + "\(only.shard.index) of \(count), from \(only.path): \(only.recorded.ending).",
        ]
        only.recorded.resultSources.map { lines.append($0) }
        only.recorded.skippedLines.map { lines.append($0) }
        return lines
    }

    /// The lines of a merge of several shards' files: how many mutants it covers, then each shard's file, how its run
    /// ended and which of its sessions tested its results.
    private func shardLines(count: Int) -> [String] {
        let given = "merged from the results files of \(parts.count) of \(count) shards"
        var lines = [
            discoveriesAgree
                ? "Report of \(latest.count) of \(Self.mutants(reference.selection.mutantsInAllShards)), \(given)."
                : "Report of \(Self.mutants(latest.count)), \(given).",
        ]
        for part in parts {
            let shard = "shard \(part.shard.index) of \(count)"
            lines.append(
                "\(shard.prefix(1).uppercased() + shard.dropFirst()), \(part.recorded.latest.count) of its "
                    + "\(Self.mutants(part.header.mutantsDiscovered)), from \(part.path): \(part.recorded.ending)."
            )
            if let sources = part.recorded.resultSources {
                lines.append("In \(shard)'s file: " + sources.prefix(1).lowercased() + sources.dropFirst())
            }
            if let skipped = part.recorded.skippedLines {
                lines.append("In \(shard)'s file: " + skipped.prefix(1).lowercased() + skipped.dropFirst())
            }
        }
        return lines
    }

    /// A line for each shard whose file wasn't given.
    private func absentShardLines(count: Int) -> [String] {
        var lines: [String] = []
        for absent in absentShards {
            lines.append(
                absent.mutants == 0
                    ? "Shard \(absent.index) of \(count) holds no mutant, so it has no results file."
                    : "No results were given for shard \(absent.index) of \(count), which holds "
                    + "\(Self.mutants(absent.mutants))."
            )
        }
        return lines
    }

    /// "1 mutant", or "2 mutants".
    private static func mutants(_ count: Int) -> String {
        count == 1 ? "1 mutant" : "\(count) mutants"
    }

    /// Whether the session `header` began kept results although changes were let through: `--force-resume` or
    /// `--force-reuse`, `--resume-ignoring` or `--reuse-ignoring`.
    private static func letChangesThrough(_ header: ResultsHeader) -> Bool {
        !(header.forced ?? []).isEmpty || !(header.waived ?? []).isEmpty
    }
}
