import Foundation

extension ShardSelection {
    /// The selection `shard` makes of `keys`, the keys of every mutant discovery found.
    init(_ shard: Shard, of keys: [MutantKey]) {
        let lines = keys.map(Self.keyLine).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var perShard = Array(repeating: 0, count: shard.count)
        for key in keys {
            perShard[Shard.index(ofPlace: key, among: shard.count) - 1] += 1
        }
        self.init(
            index: shard.index,
            count: shard.count,
            mutantsInAllShards: keys.count,
            mutantsPerShard: perShard,
            allKeysSHA256: FileDigest.sha256(of: Data(lines.joined().utf8))
        )
    }

    /// The key's path, operator, line, column and occurrence, each followed by a NUL, then a line break.
    static func keyLine(_ key: MutantKey) -> String {
        [key.path, key.mutationOperatorId.rawValue, String(key.line), String(key.column), String(key.occurrence)]
            .map { $0 + "\0" }
            .joined() + "\n"
    }
}
