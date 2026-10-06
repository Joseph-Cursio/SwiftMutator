import Foundation

/// How mutation testing stopped before testing every mutant, and what it tested until then.
struct EarlyEnd {
    /// `.interrupted` or `.aborted`.
    let reason: ResultsEnd.Reason
    /// The end line's `detail`: the stopping signal's name for an interruption, or a short code for an abort.
    let detail: String?
    /// The mutants tested so far, in job order.
    let outcome: MutationTestOutcome
    /// Every mutant this session was to test.
    let discovered: Int
}
