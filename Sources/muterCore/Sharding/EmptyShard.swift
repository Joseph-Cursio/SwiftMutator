import Foundation

/// A `--shard` run whose shard holds none of the mutants discovered, as when there are fewer than shards. Not a
/// failure: SwiftMutator says so and exits with 0, writing no report or results file, so a CI job of a matrix wider
/// than the change passes. `report` merges the other shards without it.
struct EmptyShard: Error, Equatable, CustomStringConvertible {
    let shard: Shard
    let mutantsInAllShards: Int

    var description: String {
        let holds = mutantsInAllShards == 1
            ? "doesn't hold the only mutant discovered"
            : "holds none of the \(mutantsInAllShards) mutants discovered"
        return "ℹ️ Shard \(shard.index) of \(shard.count) \(holds), so there is nothing to mutate."
    }
}
