import Foundation

/// How mutation testing stopped before testing every mutant, and what it tested until then.
struct EarlyEnd {
    /// `.interrupted` or `.aborted`.
    let reason: ResultsEnd.Reason
    /// The end line's `detail`: why it stopped, as a short code.
    let detail: String?
    /// The mutants tested so far, in job order.
    let outcome: MutationTestOutcome
    /// Every mutant this session was to test.
    let discovered: Int
}
