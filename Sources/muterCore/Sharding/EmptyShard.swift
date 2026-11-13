/// A `--shard` run whose shard holds none of the mutants discovered, as when there are fewer than shards. Not a
/// failure: SwiftMutator says so and exits with 0, writing no report or results file, so a CI job of a matrix wider
/// than the change passes. `report` merges the other shards without it.
struct EmptyShard: Error, Equatable, CustomStringConvertible {
    let shard: Shard
    /// Of a sampled split, the sample's mutants.
    let mutantsInAllShards: Int
    /// The `--sample` the shards split, when there is one that left some mutants out.
    var sample: SampleSelection?

    var description: String {
        let among = sample.map { "in the sample, of the \($0.mutantsSampledFrom) discovered" } ?? "discovered"
        let holds = mutantsInAllShards == 1
            ? "doesn't hold the only mutant \(among)"
            : "holds none of the \(mutantsInAllShards) mutants \(among)"
        return "ℹ️ Shard \(shard.index) of \(shard.count) \(holds), so there is nothing to mutate."
    }
}
