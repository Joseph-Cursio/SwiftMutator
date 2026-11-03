import Foundation

/// The run of the one mutant `--mutant` tests, which the end of the run prints in place of the report: what it
/// changes, its tests' log, its verdict, and how to run its tests with it on in the mutated project it leaves.
struct OneMutantRun: Equatable {
    let key: MutantKey
    /// The ID that switches it on.
    let switchID: String
    let snapshot: MutationOperator.Snapshot
    /// What it changes, as `MutantDiff` shows it.
    let change: [String]
    let outcome: TestSuiteOutcome
    /// The tests its run's log showed failing, as its results line records them.
    let killingTests: MutationTestOutcome.KillingTests?
    /// How long its tests took.
    let seconds: TimeInterval
    /// Its run's time limit; nil without one.
    let timeoutSeconds: TimeInterval?
    let testLog: String
    /// Where the run's log folder keeps the log; nil without a log folder.
    let logPath: String?
    /// The mutated project it was tested in, which the run leaves with no mutant switched on.
    let mutatedProject: String
    let buildSystem: BuildSystem
    /// The test command, its executable first, which builds as the baseline's does.
    let testCommand: [String]
}
