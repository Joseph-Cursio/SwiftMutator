import Foundation

/// What one session of mutation testing keeps as it goes: what it writes to its results file, each tested mutant's
/// outcome, and the worker clones it made. Only the task that runs the mutants and records their outcomes uses it, so
/// it needs no lock.
final class TestingSession {
    /// 1 for a run's first session; a resumed one is the next after the last its results file holds.
    let number: Int
    /// When mutation testing started, which its test duration is measured from.
    let startedAt: Date
    /// How long the earlier sessions' mutation testing took, all together: a resumed run's outcome adds it to this
    /// session's.
    let earlierTestDuration: TimeInterval
    /// Each job's key, in job order.
    var keys: [MutantKey] = []
    /// nil until the header is written, and for good if the file couldn't be created.
    var results: ResultsRecording?
    /// How many tested mutants the session recorded, each in a line of its own unless a write failed.
    var recorded = 0
    /// Whether a failure to write was already said, which is said once.
    var saidResultsUnwritable = false
    /// Each tested mutant's outcome by job index, kept as it is recorded, so mutation testing that stops early still
    /// has them.
    var outcomes: [Int: MutationTestOutcome.Mutation] = [:]
    /// The worker clones made so far, removed however mutation testing ends.
    var clones: [URL] = []

    init(number: Int = 1, startedAt: Date, earlierTestDuration: TimeInterval = 0) {
        self.number = number
        self.startedAt = startedAt
        self.earlierTestDuration = earlierTestDuration
    }

    /// The tested mutants' outcomes, in job order.
    var outcomesInJobOrder: [MutationTestOutcome.Mutation] {
        outcomes.sorted { $0.key < $1.key }.map(\.value)
    }
}
