import Foundation

/// How mutation testing stopped before testing every mutant, and what it tested until then.
struct EarlyEnd {
    /// `.interrupted` or `.aborted`.
    let reason: ResultsEnd.Reason
    /// The end line's `detail`: the stopping signal's name for an interruption, or a short code for an abort.
    let detail: String?
    /// The mutants tested so far, and in a resumed session the earlier results it kept, in job order.
    let outcome: MutationTestOutcome
    /// Every mutant this session was to test.
    let discovered: Int
    /// How many of `outcome`'s mutants are earlier sessions' results that a resumed session kept; 0 for a first one.
    let reused: Int
}
