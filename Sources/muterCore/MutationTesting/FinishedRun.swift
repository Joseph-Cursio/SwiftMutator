import Foundation

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

    /// How a run is timed and its progress told: the clock that times it, and the heartbeat told as it starts and
    /// ends, with `place`, where the mutant is, as the progress lines give it.
    struct Timing {
        /// The monotonic clock that times the run.
        let instant: Instant
        /// Told as each run starts and as the last ends, with the clock readings that time it.
        let heartbeat: Heartbeat
        /// Where the mutant is, as the progress lines give it.
        let place: String
    }

    /// The run of the job at `index` on `worker`, which `run` makes with `configuration`, timed by `timing`'s clock.
    /// An xcodebuild run that the simulator failed to launch (`SimulatorTrouble.launch`) runs once more on the same
    /// worker, unless mutation testing was cancelled, and that run is the one returned, whatever it comes to, with the
    /// first's failure. The mutant is still switched on: nothing else runs on the worker meanwhile. `timing`'s
    /// heartbeat is told as each run starts and as the last ends, with the clock readings that time it, so it reads the
    /// clock no more often, and with its `place`.
    static func make(
        index: Int,
        worker: Int,
        configuration: MuterConfiguration,
        timing: Timing,
        running run: () async -> TestRun
    ) async -> Self {
        let (instant, beat, place) = (timing.instant, timing.heartbeat, timing.place)
        var launched = instant()
        beat.started(place, on: worker, at: launched)
        let (testRun, failure) = await TestRun.launchedOnceMore(
            ifNeededWith: configuration,
            relaunching: {
                launched = instant()
                beat.started(place, on: worker, at: launched)
            },
            running: run
        )
        let ended = instant()
        beat.finished(on: worker, at: ended)
        return Self(
            index: index,
            worker: worker,
            run: testRun,
            seconds: PerformMutationTesting.seconds(from: launched, to: ended),
            launchFailure: failure
        )
    }

    /// This run, which wrote its output to `output`; to none, for an empty name.
    func writing(to output: String) -> Self {
        var written = self
        written.output = output.isEmpty ? nil : output
        return written
    }
}
