/// The keys of earlier sessions' results that a resumed session no longer stands by: those of the mutants it tests
/// again, of those its discovery no longer finds, and of those its sample no longer takes. A reader drops each key's
/// records before this line; a mutant line after it records the key again.
struct ResultsRetired: Codable, Equatable {
    var kind = "retired"
    let session: Int
    let keys: [MutantKey]
}
