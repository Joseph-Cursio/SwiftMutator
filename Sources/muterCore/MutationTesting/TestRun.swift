import Foundation

/// One run of the test command with a mutant switched on: what `TestSuiteOutcome.from` made of it, its log, and
/// how it ended. Only an `.exited` run has an exit status: SwiftMutator killed any other, or it couldn't run.
struct TestRun: Equatable {
    enum Ending: String, Codable {
        /// The test command exited by itself.
        case exited
        /// SwiftMutator stopped it at its time limit.
        case timedOut
        /// SwiftMutator stopped it at its first failed test (`stopAtFirstFailure`).
        case stoppedAtFailedTest
        /// Its task was cancelled, so `outcome` says nothing about the mutant.
        case cancelled
        /// Its log couldn't be opened or read, or its command couldn't start; `testLog` says why.
        case couldNotRun
    }

    let outcome: TestSuiteOutcome
    let testLog: String
    var ending: Ending = .exited
    /// `terminationStatus` for an `.exited` run: its exit code, or the signal that ended it.
    var exitStatus: Int32?
}

extension TestRun.Ending {
    /// The ending of a run that `reason` ended. One with no recorded reason exited, as
    /// `TestRunEnding.executionResult()` takes it.
    init(_ reason: TestRunEnding.Reason?) {
        switch reason {
        case .exited, nil: self = .exited
        case .timedOut: self = .timedOut
        case .failedTest: self = .stoppedAtFailedTest
        case .cancelled: self = .cancelled
        }
    }
}
