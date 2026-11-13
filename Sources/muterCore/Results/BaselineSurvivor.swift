import Foundation

/// One mutant a baseline file records as surviving: one the tests didn't kill, as it survived, timed out, or no test
/// ran its code. A key holds its mutant's line and column, which any edit above it moves, so an entry also holds what
/// its mutant changes, and its line (`BaselineMatches`).
struct BaselineSurvivor: Equatable {
    /// How it survived, which matching ignores: a timeout and a survivor flip between runs (#89), and both count
    /// against the score.
    enum Outcome: String, Codable, CaseIterable {
        case survived
        case timedOut
        case notCovered

        /// The outcome of a mutant with `outcome`, when the tests didn't kill it; nil otherwise. A mutant not covered
        /// is one whose block no test ran, never a file's row for having no coverage, which has no key.
        init?(_ outcome: TestSuiteOutcome) {
            switch outcome {
            case .passed: self = .survived
            case .timeout: self = .timedOut
            case .noCoverage: self = .notCovered
            default: return nil
            }
        }
    }

    let mutant: MutantKey
    let outcome: Outcome
    /// The mutant's snapshot: what it replaces, and what with.
    let before: String
    let after: String
    /// The line it changes, without the spaces around it (`AppliedMutationOperator.changedLine`); nil when its change
    /// spans lines, or its file had changed since it was tested, or couldn't be read.
    let line: String?

    init(mutant: MutantKey, outcome: Outcome, before: String, after: String, line: String? = nil) {
        self.mutant = mutant
        self.outcome = outcome
        self.before = before
        self.after = after
        self.line = line?.trimmingCharacters(in: .whitespaces)
    }
}
