import Foundation

/// The results files of a split's shards (`run --shard`), merged into the results of the whole run. Each shard is
/// checked against the one with the lowest index first, as a resume is checked against the run it continues, so that
/// the report holds only results a whole run would give: what a resume compares, but for the shard itself, and the
/// project's files, of which `--merge-ignoring` may let some through. A shard whose file isn't given is said, not
/// refused, as a run still going is.
struct MergedShards {
    /// One shard's results file.
    struct Part {
        let path: String
        let recorded: RecordedResults
        /// Its last session's header, which `report` reads a single file by.
        let header: ResultsHeader
        let selection: ShardSelection

        var shard: Shard {
            selection.shard
        }
    }

    /// By index.
    let parts: [Part]
    /// The build and toolchain differences `--force-merge` let through, by their names in `provenance`.
    let forced: [String]
    /// The project files that differ between the shards, which `--merge-ignoring` let through, by their paths.
    let waived: [String]
    /// Every shard's results, by key.
    let latest: [MutantKey: MutantResult]

    /// The shard the others are checked against, whose header gives the report's project paths, coverage and update
    /// notice.
    var reference: Part {
        parts[0]
    }
}

extension MergedShards {
    /// `files`, each read from its path, merged; refused, for every reason found, unless they are shards of one split
    /// that a whole run's results could be. `forcing` lets build and toolchain differences through, and `ignoring`'s
    /// globs the project files that differ.
    static func merge(
        _ files: [(path: String, recorded: RecordedResults)],
        forcing: Bool,
        ignoring globs: [String]
    ) throws -> MergedShards {
        let parts = try shards(of: files)
        let reference = parts[0]
        var reasons: [MergeRefusal] = []
        var forced: Set<String> = []
        var waived: Set<String> = []
        for part in parts.dropFirst() {
            let verdict = ResumeCheck.compare(
                part.header,
                with: ResumeCheck.Current(header: reference.header),
                forcing: forcing,
                for: .merge
            )
            reasons += verdict.refusals.map { .differs(part.shard, from: reference.shard, $0) }
            forced.formUnion(verdict.forced)
            if let tree = part.header.project, let referenceTree = reference.header.project {
                let changes = tree.changes(since: referenceTree).partition(by: globs)
                if !changes.unwaived.isEmpty {
                    reasons.append(.filesDiffer(part.shard, from: reference.shard, changes.unwaived))
                }
                waived.formUnion(changes.waived.map(\.path))
            }
            if part.selection.allKeysSHA256 == reference.selection.allKeysSHA256,
               part.selection.mutantsPerShard != reference.selection.mutantsPerShard {
                reasons.append(.splitDifferently(part.shard, from: reference.shard))
            }
        }
        var latest: [MutantKey: MutantResult] = [:]
        var testedTwice: Set<MutantKey> = []
        for part in parts {
            for (key, result) in part.recorded.latest {
                let earlier = latest.updateValue(result, forKey: key)
                if earlier != nil {
                    testedTwice.insert(key)
                }
            }
        }
        if !testedTwice.isEmpty {
            reasons.append(.testedTwice(testedTwice.sorted { $0.description < $1.description }))
        }
        guard reasons.isEmpty else { throw MergeRefused(reasons: reasons) }
        return MergedShards(parts: parts, forced: forced.sorted(), waived: waived.sorted(), latest: latest)
    }

    /// Each of `files` as a shard, by index; refused unless every one is a shard's, all of one split, none given twice.
    private static func shards(of files: [(path: String, recorded: RecordedResults)]) throws -> [Part] {
        var reasons: [MergeRefusal] = []
        var parts: [Part] = []
        for file in files {
            guard let header = file.recorded.headers.last, let selection = header.shard else {
                reasons.append(.notAShard(path: file.path))
                continue
            }
            parts.append(Part(path: file.path, recorded: file.recorded, header: header, selection: selection))
        }
        if Set(parts.map(\.shard.count)).count > 1 {
            reasons.append(.otherSplits(parts.map { MergeRefusal.ShardFile(path: $0.path, shard: $0.shard) }))
        }
        // Stable, so a shard given twice keeps the order its files were given in.
        let sorted = parts.enumerated()
            .sorted { ($0.element.shard.index, $0.offset) < ($1.element.shard.index, $1.offset) }
            .map(\.element)
        let repeated = Dictionary(grouping: sorted, by: \.shard).values
            .filter { $0.count > 1 }
            .sorted { ($0[0].shard.index, $0[0].shard.count) < ($1[0].shard.index, $1[0].shard.count) }
        reasons += repeated.map { .givenTwice($0[0].shard, paths: $0.map(\.path)) }
        guard reasons.isEmpty else { throw MergeRefused(reasons: reasons) }
        return sorted
    }
}

extension MergedShards {
    /// Whether every shard discovered the same mutants: then how many have no result is known exactly.
    var discoveriesAgree: Bool {
        parts.allSatisfy { $0.selection.allKeysSHA256 == reference.selection.allKeysSHA256 }
    }

    /// The indices of the shards whose files weren't given, with how many mutants each holds, as the reference shard's
    /// discovery split them.
    var absentShards: [(index: Int, mutants: Int)] {
        let given = Set(parts.map(\.shard.index))
        return (1...reference.shard.count).filter { !given.contains($0) }.map { index in
            (index, reference.selection.mutantsPerShard.indices.contains(index - 1)
                ? reference.selection.mutantsPerShard[index - 1]
                : 0)
        }
    }

    /// Whether `report` exits as a run that stopped on an error does: a shard did, or the file of a shard that holds
    /// mutants wasn't given, so a CI job that checks the merged report fails as one that checked a shard would.
    var stoppedOnAnError: Bool {
        parts.contains { $0.recorded.stoppedOnAnError } || absentShards.contains { $0.mutants > 0 }
    }

    /// The outcome a whole run of the merged mutants would have reported: under the reference shard's project paths,
    /// coverage and update notice, and with the longest shard's test duration, as the shards are meant to run at once.
    func mutationTestOutcome() -> MutationTestOutcome {
        MutationTestOutcome(
            records: latest.values,
            under: reference.header,
            testDuration: parts.map(\.recorded.testDuration).max() ?? 0,
            shards: nil
        )
    }

    /// What `report` says on standard error of the merge: how many mutants it covers, each shard's file and how its run
    /// ended, the shards whose files weren't given, and what may make the report differ from a whole run's.
    func statusLines() -> [String] {
        let count = reference.shard.count
        let given = "merged from the results files of \(parts.count) of \(count) shards"
        var lines = [
            discoveriesAgree
                ? "Report of \(latest.count) of \(reference.selection.mutantsInAllShards) mutants, \(given)."
                : "Report of \(latest.count) mutants, \(given).",
        ]
        for part in parts {
            let shard = "shard \(part.shard.index) of \(count)"
            lines.append(
                "\(shard.prefix(1).uppercased() + shard.dropFirst()), \(part.recorded.latest.count) of its "
                    + "\(part.header.mutantsDiscovered) mutants, from \(part.path): \(part.recorded.ending)."
            )
            if let skipped = part.recorded.skippedLines {
                lines.append("In \(shard)'s file: " + skipped.prefix(1).lowercased() + skipped.dropFirst())
            }
        }
        for absent in absentShards {
            lines.append(
                absent.mutants == 0
                    ? "Shard \(absent.index) of \(count) holds no mutant, so it has no results file."
                    : "No results file was given for shard \(absent.index) of \(count), which holds "
                    + (absent.mutants == 1 ? "1 mutant." : "\(absent.mutants) mutants.")
            )
        }
        if !discoveriesAgree {
            let found = parts.map { "\($0.selection.mutantsInAllShards) in shard \($0.shard.index) of \(count)" }
            lines.append(
                "The shards discovered different mutants, \(Logger.listed(found)), so a mutant that some of them "
                    + "didn't discover may have no result."
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

    /// Whether the session `header` began kept results although changes were let through: `--force-resume` or
    /// `--force-reuse`, `--resume-ignoring` or `--reuse-ignoring`.
    private static func letChangesThrough(_ header: ResultsHeader) -> Bool {
        !(header.forced ?? []).isEmpty || !(header.waived ?? []).isEmpty
    }
}
