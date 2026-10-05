import Foundation

/// What one session of mutation testing writes to its results file as it goes. Only the task that runs the mutants
/// and records their outcomes uses it, so it needs no lock.
final class TestingSession {
    /// 1 for now; a resumed run will add the next session to the same file.
    let number: Int
    /// When mutation testing started, which its test duration is measured from.
    let startedAt: Date
    /// Each job's key, in job order.
    var keys: [MutantKey] = []
    /// nil until the header is written, and for good if the file couldn't be created.
    var results: ResultsRecording?
    /// How many tested mutants the session recorded, each in a line of its own unless a write failed.
    var recorded = 0
    /// Whether a failure to write was already said, which is said once.
    var saidResultsUnwritable = false

    init(number: Int = 1, startedAt: Date) {
        self.number = number
        self.startedAt = startedAt
    }
}
