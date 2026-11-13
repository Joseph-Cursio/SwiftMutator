/// The shards of a `--shard` split a report covers, as it says: the one a run tested, or those `report` merged when
/// some are missing.
struct ShardScope: Codable, Equatable {
    /// Sorted.
    let indices: [Int]
    let count: Int
    /// How many mutants were discovered in every shard together.
    let mutantsInAllShards: Int

    init(indices: [Int], count: Int, mutantsInAllShards: Int) {
        self.indices = indices.sorted()
        self.count = count
        self.mutantsInAllShards = mutantsInAllShards
    }

    /// The shard `selection` tested.
    init(_ selection: ShardSelection) {
        self.init(indices: [selection.index], count: selection.count, mutantsInAllShards: selection.mutantsInAllShards)
    }

    /// "shard 1 of 2", or "shards 1 and 3 of 4".
    var named: String {
        let listedIndices = Logger.listed(indices.map(String.init))
        return (self.indices.count == 1 ? "shard " : "shards ") + "\(listedIndices) of \(count)"
    }

    /// "Only the mutants in shard 1 of 2 were tested, of 2463 discovered in every shard." Of a `sampled` split, the
    /// shards split the sample, whose mutants they count: "…, of 500 in every shard of the sample."
    func sentence(sampled: Bool = false) -> String {
        "Only the mutants in \(named) were tested, of \(mutantsInAllShards) "
            + (sampled ? "in every shard of the sample." : "discovered in every shard.")
    }
}
