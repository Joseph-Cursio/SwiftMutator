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
        /// SwiftMutator stopped it at a test process's crash, before any failed test (`stopAtFirstFailure`).
        case stoppedAtCrash
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
        case .crashed: self = .stoppedAtCrash
        case .cancelled: self = .cancelled
        }
    }
}

/// A mutant's finished test run, as mutation testing records it.
struct FinishedRun {
    /// The mutant's position in this session's jobs.
    let index: Int
    /// Where it ran: 0 is the mutated project, n is its clone `<mutated>_worker<n>`.
    let worker: Int
    let run: TestRun
    /// From launch to classification, on the monotonic clock.
    let seconds: TimeInterval
    /// The run before this one, if the simulator failed to launch it, so that this one ran in its place.
    var launchFailure: LaunchFailure?
}

extension FinishedRun {
    /// The run of the job at `index` on `worker`, which `run` makes with `configuration`, timed by `instant`. An
    /// xcodebuild run that the simulator failed to launch (`SimulatorTrouble.launch`) runs once more on the same
    /// worker, unless mutation testing was cancelled, and that run is the one returned, whatever it comes to, with the
    /// first's failure. The mutant is still switched on: nothing else runs on the worker meanwhile.
    static func make(
        index: Int,
        worker: Int,
        configuration: MuterConfiguration,
        instant: Instant,
        running run: () async -> TestRun
    ) async -> FinishedRun {
        var launched = instant()
        var testRun = await run()
        var launchFailure: LaunchFailure?
        if case let .launch(line) = SimulatorTrouble.of(testRun, with: configuration), !Task.isCancelled {
            launchFailure = LaunchFailure(line: line, testLog: testRun.testLog)
            launched = instant()
            testRun = await run()
        }
        return FinishedRun(
            index: index,
            worker: worker,
            run: testRun,
            seconds: PerformMutationTesting.seconds(from: launched, to: instant()),
            launchFailure: launchFailure
        )
    }
}
