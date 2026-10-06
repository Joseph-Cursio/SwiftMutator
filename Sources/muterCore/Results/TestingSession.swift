import Foundation

/// What one session of mutation testing keeps as it goes: what it writes to its results file, each mutant's outcome,
/// tested or kept from an earlier session, and the worker clones it made. Only the task that runs the mutants and
/// records their outcomes uses it, so it needs no lock.
final class TestingSession {
    /// 1 for a run's first session; a resumed one is the next after the last its results file holds.
    let number: Int
    /// When mutation testing started, which its test duration is measured from.
    let startedAt: Date
    /// How long the earlier sessions' mutation testing took, all together: a resumed run's outcome adds it to this
    /// session's.
    let earlierTestDuration: TimeInterval
    /// Each job's key, in job order, known before the baseline runs.
    var keys: [MutantKey] = []
    /// Whether the baseline passed. Until it has, mutation testing that stops has nothing to report, and posts no
    /// early end: an abort says why.
    var baselinePassed = false
    /// nil until the header is written, and for good if the file couldn't be created.
    var results: ResultsRecording?
    /// How many tested mutants the session recorded, each in a line of its own unless a write failed.
    var recorded = 0
    /// How many of `outcomes` are earlier sessions' results that a resumed session kept rather than tested again.
    var reused = 0
    /// The jobs, by index, whose result an earlier session recorded as a build error, which a resumed session tests
    /// again. It tests them one after another, where the first session tested other mutants between them, so one that
    /// fails to build again doesn't count toward the build errors in a row that stop mutation testing.
    var earlierBuildErrors: Set<Int> = []
    /// Whether a failure to write was already said, which is said once.
    var saidResultsUnwritable = false
    /// Each mutant's outcome by job index: a kept result's once the header is written, and a tested one's as it is
    /// recorded, so mutation testing that stops early still has them.
    var outcomes: [Int: MutationTestOutcome.Mutation] = [:]
    /// The worker clones made so far, removed however mutation testing ends.
    var clones: [URL] = []

    init(number: Int = 1, startedAt: Date, earlierTestDuration: TimeInterval = 0) {
        self.number = number
        self.startedAt = startedAt
        self.earlierTestDuration = earlierTestDuration
    }

    /// The outcomes, tested and kept alike, in job order.
    var outcomesInJobOrder: [MutationTestOutcome.Mutation] {
        outcomes.sorted { $0.key < $1.key }.map(\.value)
    }
}
