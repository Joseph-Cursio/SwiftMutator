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
        /// SwiftMutator stopped it at a test process's crash, before any failed test (`stopAtFirstFailure`).
        case stoppedAtCrash
        /// Its task was cancelled, so `outcome` says nothing about the mutant.
        case cancelled
        /// Its log couldn't be opened or read, or its command couldn't start; `testLog` says why. Also a mutant that
        /// doesn't compile, whose tests were never run (`CompileRecovery`).
        case couldNotRun

        /// The ending of a run that `reason` ended. One with no recorded reason exited, as
        /// `TestRunEnding.executionResult()` takes it.
        init(_ reason: TestRunEnding.Reason?) {
            switch reason {
            case .exited, nil: self = .exited
            case .timedOut: self = .timedOut
            case .failedTest: self = .stoppedAtFailedTest
            case .crashed: self = .stoppedAtCrash
            case .cancelled: self = .cancelled
            }
        }
    }

    let outcome: TestSuiteOutcome
    let testLog: String
    var ending: Ending = .exited
    /// `terminationStatus` for an `.exited` run: its exit code, or the signal that ended it.
    var exitStatus: Int32?
    /// Whether the mutant's block ran (`MutantActivation`). Always test for `didNotRun`, never `!= .ran`: `unknown`
    /// keeps a verdict as it would be without markers.
    var activated: MutantActivation = .unknown

    /// The run that `run` makes with `configuration`, or, if the simulator failed to launch it
    /// (`SimulatorTrouble.launch`) and the task isn't cancelled, the one `run` makes next, on the same worker, in its
    /// place, whatever it comes to, with the first's failure. `relaunching` is called just before the second starts.
    static func launchedOnceMore(
        ifNeededWith configuration: MuterConfiguration,
        relaunching: () -> Void = {},
        running run: () async -> Self
    ) async -> (run: Self, launchFailure: LaunchFailure?) {
        let testRun = await run()
        guard case let .launch(line) = SimulatorTrouble.of(testRun, with: configuration), !Task.isCancelled else {
            return (testRun, nil)
        }
        relaunching()
        return (await run(), LaunchFailure(line: line, testLog: testRun.testLog))
    }
}
