import Foundation

/// The timeouts of a session's mutants that it tests again once the others are tested, fewer at once and under the
/// same limit: with every worker's tests competing for the same cores, a slow test can pass a limit that it keeps to
/// under less load, while a mutant that loops forever times out again.
struct TimeoutReruns: Equatable {
    /// How many timeouts are tested again.
    let count: Int
    /// How many of them are tested at once.
    let workers: Int
    /// The time limit of each run, the one their first runs had.
    let limitSeconds: TimeInterval?

    /// The longest the reruns can take: each one stopped at the limit, `workers` at once.
    var longestSeconds: TimeInterval? {
        limitSeconds.map { ceil(Double(count) / Double(max(workers, 1))) * $0 }
    }
}

/// A timeout tested again: what it came to this time, its log, and how long its run took.
struct TimeoutRerun {
    /// The outcome of this run, which the results file records after the first run's timeout, so it stands.
    let rerun: MutationTestOutcome.Mutation
    /// This run's log, kept under a name of its own (`MutationTestLog.rerunFileName(for:)`).
    let log: MutationTestLog
    /// From launch to classification.
    let seconds: TimeInterval
    /// Which of the reruns it is, from 1, in the order they finished, and how many there are.
    let number: Int
    let count: Int

    /// Whether this run's verdict isn't the first run's, a timeout.
    var changed: Bool {
        rerun.testSuiteOutcome != .timeout
    }
}

/// What the timeouts tested again came to, so far.
struct TimeoutRerunTally: Equatable {
    let reruns: TimeoutReruns
    private(set) var rerun = 0
    private(set) var killed = 0
    private(set) var survived = 0
    private(set) var timedOutAgain = 0
    private(set) var buildErrors = 0

    init(_ reruns: TimeoutReruns) {
        self.reruns = reruns
    }

    /// How many came to something other than a timeout.
    var changed: Int {
        rerun - timedOutAgain
    }

    /// Counts a rerun that came to `outcome`. A crash counts as a kill, as the report's score counts it.
    mutating func add(_ outcome: TestSuiteOutcome) {
        rerun += 1
        switch outcome {
        case .failed, .runtimeError: killed += 1
        case .passed: survived += 1
        case .timeout: timedOutAgain += 1
        case .buildError: buildErrors += 1
        case .noCoverage: break
        }
    }
}
