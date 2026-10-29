import Foundation

typealias MutationOutcomeWithFlush = (mutation: MutationTestOutcome.Mutation, fflush: () -> Void)

/// Sendable, as the run's options hold one, and the command's task hands them to the run's work. A reporter keeps no
/// state, only its dependencies, so each is a struct.
protocol Reporter: Sendable {
    func newMutationTestOutcomeAvailable(outcomeWithFlush: MutationOutcomeWithFlush)
    func report(from outcome: MutationTestOutcome) -> String
}

extension Reporter {
    func newMutationTestOutcomeAvailable(outcomeWithFlush: MutationOutcomeWithFlush) {}
}
