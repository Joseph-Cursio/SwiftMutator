import Foundation

/// The results files of a split's shards (`run --shard`), merged into the results of the whole run: one shard's file
/// alone too, a merge of one, so that a CI job's glob that finds one file is judged as one that finds two. Each shard
/// is checked against the one with the lowest index first, as a resume is checked against the run it continues, so
/// that the report holds only results a whole run would give: what a resume compares, but for the shard itself, and
/// the project's files, of which `--merge-ignoring` may let some through. A shard whose file isn't given, or whose run
/// didn't finish, is said, not refused, as a run still going is; but `report` then fails.
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

    /// Each of `files` as a shard, by index; refused unless every one is a shard's, whose counts hold together, all of
    /// one split, none given twice.
    private static func shards(of files: [(path: String, recorded: RecordedResults)]) throws -> [Part] {
        var reasons: [MergeRefusal] = []
        var parts: [Part] = []
        for file in files {
            guard let header = file.recorded.headers.last, let selection = header.shard else {
                reasons.append(.notAShard(path: file.path))
                continue
            }
            guard selection.holdsTogether(withShardsMutants: header.mutantsDiscovered) else {
                reasons.append(.inconsistentShard(path: file.path))
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

    /// Whether `report` exits as a run that stopped on an error does: when the report is known to lack results. A shard
    /// stopped on an error; or has fewer results than mutants, as one that was interrupted or killed, or is still
    /// running; or the file of a shard that holds mutants wasn't given. So a CI job that checks the report fails as one
    /// that checked every shard's run would. Discoveries that differ only warn: each shard has its own mutants'
    /// results.
    var lacksResults: Bool {
        parts.contains { $0.recorded.stoppedOnAnError || $0.recorded.latest.count < $0.header.mutantsDiscovered }
            || absentShards.contains { $0.mutants > 0 }
    }

    /// The shards the report covers, when it covers only some: those given, unless every shard that holds mutants is.
    var scope: ShardScope? {
        guard absentShards.contains(where: { $0.mutants > 0 }) else { return nil }
        return ShardScope(
            indices: parts.map(\.shard.index),
            count: reference.shard.count,
            mutantsInAllShards: reference.selection.mutantsInAllShards
        )
    }

    /// The outcome a whole run of the merged mutants would have reported: under the reference shard's project paths,
    /// coverage and update notice, and with the longest shard's test duration, as the shards are meant to run at once;
    /// of the shards given, if some that hold mutants aren't.
    ///
    /// The results of a sample's shards are cut short when one of those given has some of its results, but not all:
    /// they are then its first files'. A shard with none, as one whose job was cancelled before its first mutant, or
    /// whose file isn't given, leaves the others a random part of the sample, as a shard's hash doesn't depend on the
    /// seed.
    func mutationTestOutcome() -> MutationTestOutcome {
        MutationTestOutcome(
            records: latest.values,
            under: reference.header,
            testDuration: parts.map(\.recorded.testDuration).max() ?? 0,
            shards: scope,
            sampleIsCutShort: parts.contains { (1..<$0.header.mutantsDiscovered).contains($0.recorded.latest.count) }
        )
    }

    /// What `report` says on standard error of the merge: how many mutants it covers, each shard's file and how its run
    /// ended and which of its sessions tested its results, the shards whose files weren't given, and what may make the
    /// report differ from a whole run's. One shard's file alone is said as any other file is, naming its shard.
    func statusLines() -> [String] {
        let count = reference.shard.count
        var lines: [String]
        if parts.count == 1 {
            let only = reference
            lines = [
                "Report of \(only.recorded.latest.count) of \(Self.mutants(only.header.mutantsDiscovered)) in shard "
                    + "\(only.shard.index) of \(count), from \(only.path): \(only.recorded.ending).",
            ]
            only.recorded.resultSources.map { lines.append($0) }
            only.recorded.skippedLines.map { lines.append($0) }
        } else {
            let given = "merged from the results files of \(parts.count) of \(count) shards"
            lines = [
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
        }
        for absent in absentShards {
            lines.append(
                absent.mutants == 0
                    ? "Shard \(absent.index) of \(count) holds no mutant, so it has no results file."
                    : "No results file was given for shard \(absent.index) of \(count), which holds "
                    + "\(Self.mutants(absent.mutants))."
            )
        }
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

private extension ShardSelection {
    /// Whether the counts hold together as every header SwiftMutator writes has them, the shard's own being `mutants`:
    /// a header edited by hand may not, and then nothing shows what its shard holds.
    func holdsTogether(withShardsMutants mutants: Int) -> Bool {
        guard (1...Shard.largestCount).contains(count), (1...count).contains(index),
              mutantsPerShard.count == count, mutantsPerShard.allSatisfy({ $0 >= 0 }),
              mutantsPerShard[index - 1] == mutants
        else { return false }
        // Added up without trapping, as counts that large hold together no more than negative ones.
        var total = 0
        for shardsMutants in mutantsPerShard {
            let (sum, overflowed) = total.addingReportingOverflow(shardsMutants)
            guard !overflowed else { return false }
            total = sum
        }
        return total == mutantsInAllShards
    }
}
