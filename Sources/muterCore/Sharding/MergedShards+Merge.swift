import ArgumentParser
import Foundation

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
