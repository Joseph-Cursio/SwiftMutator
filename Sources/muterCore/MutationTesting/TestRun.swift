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
        /// Its log couldn't be opened or read, or its command couldn't start; `testLog` says why. Also a mutant that
        /// doesn't compile, whose tests were never run (`CompileRecovery`).
        case couldNotRun
    }

    let outcome: TestSuiteOutcome
    let testLog: String
    var ending: Ending = .exited
    /// `terminationStatus` for an `.exited` run: its exit code, or the signal that ended it.
    var exitStatus: Int32?
    /// Whether the mutant's block ran (`ActivationMarker`): true if its marker was created; false if the run reached
    /// mutated code, but not the mutant's block; nil if the run showed neither, as a host that can't write there
    /// doesn't. Always test for `false`, never `!= true`: nil keeps a verdict as it would be without markers.
    var activated: Bool?
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

extension TestRun {
    /// The run that `run` makes with `configuration`, or, if the simulator failed to launch it
    /// (`SimulatorTrouble.launch`) and the task isn't cancelled, the one `run` makes next, on the same worker, in its
    /// place, whatever it comes to, with the first's failure. `relaunching` is called just before the second starts.
    static func launchedOnceMore(
        ifNeededWith configuration: MuterConfiguration,
        relaunching: () -> Void = {},
        running run: () async -> TestRun
    ) async -> (run: TestRun, launchFailure: LaunchFailure?) {
        let testRun = await run()
        guard case let .launch(line) = SimulatorTrouble.of(testRun, with: configuration), !Task.isCancelled else {
            return (testRun, nil)
        }
        relaunching()
        return (await run(), LaunchFailure(line: line, testLog: testRun.testLog))
    }
}

/// A mutant's finished test run, as mutation testing records it.
struct FinishedRun {
    /// The mutant's position in this session's jobs.
    let index: Int
    /// Where it ran: for SwiftPM, 0 is the mutated project and n its clone `<project>_mutated_worker<n>.noindex`; for
    /// xcodebuild, n is the worker whose simulator, `.xctestrun` and derived data it used
    /// (`MuterConfiguration.XcodeWorker`).
    let worker: Int
    var run: TestRun
    /// From launch to classification, on the monotonic clock.
    let seconds: TimeInterval
    /// The run before this one, if the simulator failed to launch it, so that this one ran in its place.
    var launchFailure: LaunchFailure?
    /// The file it wrote its output to, as given to the run, which recording it moves to the name its log is kept
    /// under, or removes; nil if it has none.
    var output: String?
}

extension FinishedRun {
    /// The run of the job at `index` on `worker`, which `run` makes with `configuration`, timed by `instant`. An
    /// xcodebuild run that the simulator failed to launch (`SimulatorTrouble.launch`) runs once more on the same
    /// worker, unless mutation testing was cancelled, and that run is the one returned, whatever it comes to, with the
    /// first's failure. The mutant is still switched on: nothing else runs on the worker meanwhile. `heartbeat` is told
    /// as each run starts and as the last ends, with the clock readings that time it, so it reads the clock no more
    /// often, and with `place`, where the mutant is, as the progress lines give it.
    static func make(
        index: Int,
        worker: Int,
        configuration: MuterConfiguration,
        instant: Instant,
        heartbeat: (heartbeat: Heartbeat, place: String),
        running run: () async -> TestRun
    ) async -> FinishedRun {
        let (heartbeat, place) = heartbeat
        var launched = instant()
        heartbeat.started(place, on: worker, at: launched)
        let (testRun, launchFailure) = await TestRun.launchedOnceMore(
            ifNeededWith: configuration,
            relaunching: {
                launched = instant()
                heartbeat.started(place, on: worker, at: launched)
            },
            running: run
        )
        let ended = instant()
        heartbeat.finished(on: worker, at: ended)
        return FinishedRun(
            index: index,
            worker: worker,
            run: testRun,
            seconds: PerformMutationTesting.seconds(from: launched, to: ended),
            launchFailure: launchFailure
        )
    }

    /// This run, which wrote its output to `output`; to none, for an empty name.
    func writing(to output: String) -> FinishedRun {
        var run = self
        run.output = output.isEmpty ? nil : output
        return run
    }
}
