#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// What a session run with `--shard` records of its split in the results file's header: which shard it tested, and
/// what discovery found in every shard, so that `report` can check that the shards it merges discovered the same
/// mutants, and say how many have no result, those of a shard whose file it wasn't given included.
struct ShardSelection: Codable, Equatable, Sendable {
    let index: Int
    let count: Int
    /// How many mutants discovery found in every shard together. The header's own `mutantsDiscovered` counts this
    /// shard's.
    let mutantsInAllShards: Int
    /// How many of them each shard holds, shard 1's first, so that a shard with none, which writes no results file,
    /// can be told from one whose file is missing.
    let mutantsPerShard: [Int]
    /// SHA-256 over a line for each of those mutants' keys (`keyLine`), sorted: shards whose discoveries found the same
    /// mutants have the same.
    let allKeysSHA256: String

    var shard: Shard {
        Shard(index: index, count: count)
    }

    /// What a report of this shard's results alone covers: this shard, unless no other shard holds a mutant, when its
    /// results are the whole run's. The run's own report and `report` of its file both say so.
    var scopeAlone: ShardScope? {
        let othersAreEmpty = mutantsPerShard.indices.allSatisfy { $0 == index - 1 || mutantsPerShard[$0] == 0 }
        return othersAreEmpty ? nil : ShardScope(self)
    }
}

/// `--shard k/n`: the kth of n shards the discovered mutants are split into, so that n runs, on as many machines, test
/// every mutant once between them. A mutant's shard follows from its place alone, its key without the occurrence
/// (`MutantKey`): the same on every machine, whatever else each one discovers, with no plan to pass around.
struct Shard: Hashable, Sendable, CustomStringConvertible {
    /// From 1 to `count`.
    let index: Int
    let count: Int

    /// The most shards a run can be split into: far more machines than a split is worth, and few enough that every
    /// header's count of each shard's mutants (`ShardSelection.mutantsPerShard`) stays short.
    static let largestCount = 1_000

    init(index: Int, count: Int) {
        self.index = index
        self.count = count
    }

    /// `k/n`, two whole numbers with 1 ≤ k ≤ n ≤ `largestCount`; nil for anything else.
    init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }),
              let parsedIndex = Int(parts[0]),
              let parsedCount = Int(parts[1]),
              parsedIndex >= 1,
              parsedIndex <= parsedCount,
              parsedCount <= Self.largestCount
        else { return nil }
        self.init(index: parsedIndex, count: parsedCount)
    }

    /// "1/2", as `--shard` takes it.
    var description: String {
        "\(index)/\(count)"
    }

    /// Whether this shard and `other` can hold a mutant in common: whether some number leaves this shard's remainder
    /// divided by its count, and `other`'s divided by its, which is when the two remainders are the same modulo the
    /// counts' greatest common divisor. Two shards of one split never can.
    func overlaps(_ other: Self) -> Bool {
        var (larger, smaller) = (max(count, other.count), min(count, other.count))
        while smaller > 0 {
            (larger, smaller) = (smaller, larger % smaller)
        }
        return (index - 1) % larger == (other.index - 1) % larger
    }

    /// Whether this shard holds the mutant whose key is `key`.
    func holds(_ key: MutantKey) -> Bool {
        Self.index(ofPlace: key, among: count) == index
    }

    /// The shard, of `count`, that holds the mutants at `key`'s place, whatever its occurrence: SHA-256 over the
    /// place's path, operator, line and column, each followed by a NUL, its first 8 bytes read as a big-endian number,
    /// modulo `count`, plus 1. Not Swift's `hashValue`, which each process seeds afresh.
    ///
    /// By the place, so that every repeat of one place and operator is in one shard: a shard's jobs then number their
    /// occurrences as a whole run's do (`MutantKey.keys`), and its keys are the whole run's.
    static func index(ofPlace key: MutantKey, among count: Int) -> Int {
        let place = [key.path, key.mutationOperatorId.rawValue, String(key.line), String(key.column)]
            .map { $0 + "\0" }
            .joined()
        let digest = SHA256.hash(data: Data(place.utf8))
        let number = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Int(number % UInt64(count)) + 1
    }
}

extension [SchemataMutationMapping] {
    /// Of these mappings, every discovered mutant in the mutated project at `projectRoot`, only the ones `shard` holds,
    /// and what it recorded of the split. A file left with none is left out.
    func keepingOnly(_ shard: Shard, under projectRoot: URL) -> (mappings: Self, selection: ShardSelection) {
        let keys = MutantKey.keys(for: flatMap(\.mutationSchemata), under: projectRoot)
        let kept: Self = compactMap { mapping in
            var kept = mapping
            kept.keepOnly { schema in
                shard.holds(MutantKey(
                    path: RepoRelativePath.of(schema.filePath, under: projectRoot),
                    mutationOperatorId: schema.mutationOperatorId,
                    line: schema.position.line,
                    column: schema.position.column,
                    occurrence: 0
                ))
            }
            return kept.isEmpty ? nil : kept
        }
        return (kept, ShardSelection(shard, of: keys))
    }
}
