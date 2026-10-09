import Foundation

/// The signal that stopped this run, if one did. `Interruptions` records it before it cancels the run, so that the
/// end line can name it.
final class InterruptionRecord: @unchecked Sendable { // `first` is behind `lock`
    private let lock = NSLock()
    private var first: Int32?

    /// The first stopping signal, or nil if none came.
    var signal: Int32? { lock.withLock { first } }

    /// Records `signal` unless one was recorded before, and returns whether it did.
    func record(_ signal: Int32) -> Bool {
        lock.withLock {
            guard first == nil else { return false }
            first = signal
            return true
        }
    }

    static func name(of signal: Int32) -> String {
        [SIGINT: "SIGINT", SIGTERM: "SIGTERM", SIGHUP: "SIGHUP"][signal] ?? "signal \(signal)"
    }
}

/// Runs a command's work so that SIGINT, SIGTERM and SIGHUP stop it cleanly. Each process SwiftMutator starts leads a
/// process group of its own, so a terminal's Ctrl-C reaches SwiftMutator alone, and stopping them is up to it.
final class Interruptions: @unchecked Sendable { // `timers` is touched only on `queue`
    static let stoppingSignals = [SIGINT, SIGTERM, SIGHUP]

    /// How the work ended, and the signal that stopped it, if one came while it ran.
    struct Ended {
        let result: Result<Void, Error>
        let signal: Int32?
    }

    @Dependency(\.interruption)
    private var record: InterruptionRecord
    @Dependency(\.standardOutIsATerminal)
    private var standardOutIsATerminal: Bool
    private let observer: SignalObserving
    private let killDescendants: @Sendable () -> Void
    private let exit: @Sendable (Int32) -> Void
    private let say: @Sendable (String) -> Void
    private let gracePeriod: TimeInterval
    private let sweepInterval: TimeInterval
    private let queue = DispatchQueue(label: "SwiftMutator.interruptions")
    private var timers: [DispatchSourceTimer] = []

    /// `say` writes to standard error with `fputs`: it reaches the terminal even when a `| tee` that the same Ctrl-C
    /// ended has closed standard output, and `FileHandle.write(_:)` raises an exception once the terminal has hung up.
    init(
        observer: SignalObserving = DispatchSignalObserver(),
        killDescendants: @escaping @Sendable () -> Void = { ProcessTree.killDescendantsOfThisProcess() },
        exit: @escaping @Sendable (Int32) -> Void = { Interruptions.exit(by: $0) },
        say: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) },
        gracePeriod: TimeInterval = 30,
        sweepInterval: TimeInterval = 0.25
    ) {
        self.observer = observer
        self.killDescendants = killDescendants
        self.exit = exit
        self.say = say
        self.gracePeriod = gracePeriod
        self.sweepInterval = sweepInterval
    }

    /// Runs `work` until it ends. The first stopping signal cancels it, kills every process SwiftMutator started, and
    /// keeps killing new ones until `work` ends; a second signal, other than a SIGHUP after a first SIGHUP, or
    /// `gracePeriod` seconds without `work` ending, ends SwiftMutator at once, by the first signal. Once a signal came,
    /// the caller is to exit by it, which a second signal meanwhile still does at once.
    func run(_ work: @escaping @Sendable () async throws -> Void) async -> Ended {
        let task = Task { try await work() }
        observer.start(observing: Self.stoppingSignals, on: queue) { [self] signal in
            received(signal, stopping: task)
        }
        let result = await task.result
        // On the queue, so that no handler is under way. Once a signal came, the observer stays, so that a second one
        // still ends SwiftMutator at once.
        let signal: Int32? = queue.sync {
            timers.forEach { $0.cancel() }
            timers = []
            if record.signal == nil { observer.stop() }
            return record.signal
        }
        if signal != nil { killDescendants() } // whatever started after the last sweep
        return Ended(result: result, signal: signal)
    }

    /// On `queue`. Nothing that stops a run may start a process: the sweep would kill it.
    private func received(_ signal: Int32, stopping task: Task<Void, Error>) {
        guard record.record(signal) else {
            // When its terminal closes, zsh sends the job SIGHUP twice, about a millisecond apart. Nobody is left to
            // ask for a stop at once, and `gracePeriod` still bounds the stop.
            if signal == SIGHUP, record.signal == SIGHUP { return }
            killDescendants()
            say("⏹ Stopping at once. SwiftMutator removes worker copies it leaves behind when it next runs.")
            exit(record.signal ?? signal)
            return
        }
        // First: every run's cancellation handler then records it cancelled before anything kills its process, so no
        // run that stopping ended is recorded as a mutant's result.
        task.cancel()
        // Then what no cancellation reaches, now and every `sweepInterval` until the work ends: coverage, `cp`, `find`,
        // `which` and the steps' later processes, which a step starts one after another.
        killDescendants()
        // Said after both, so that a standard error nobody reads can't hold them up.
        say(Self.stoppingMessage(for: signal, leavingRoomForTheProgressBar: standardOutIsATerminal))
        schedule(after: sweepInterval, repeating: sweepInterval) { [self] in killDescendants() }
        schedule(after: gracePeriod) { [self] in
            killDescendants()
            say("⏹ SwiftMutator hasn't stopped after \(Int(gracePeriod)) seconds, so it is stopping at once.")
            exit(signal)
        }
    }

    /// Followed by two empty lines when `leavingRoomForTheProgressBar`, as on a terminal, the only place a progress bar
    /// is drawn, so that a redraw in the meantime moves up over them, not over the message. A repeated SIGHUP doesn't
    /// stop at once, so it isn't offered after one.
    static func stoppingMessage(for signal: Int32, leavingRoomForTheProgressBar: Bool = true) -> String {
        let again: String
        switch signal {
        case SIGINT: again = "Press Ctrl-C again"
        case SIGHUP: again = "Send SIGINT or SIGTERM"
        default: again = "Send another SIGINT, SIGTERM or SIGHUP"
        }
        return "⏹ Stopping (\(InterruptionRecord.name(of: signal))): ending the test runs under way and keeping what "
            + "was tested. \(again) to stop at once." + (leavingRoomForTheProgressBar ? "\n\n" : "")
    }

    /// Ends SwiftMutator by `signal`, as its default action would have, so that a shell sees it die of the signal, and
    /// a script or loop running it stops too. Sent to the process, not this thread: from a Dispatch thread, `raise()`
    /// left the signal pending, and the fallback ran instead in 44 of 45 lab runs.
    static func exit(by signal: Int32) -> Never {
        fflush(stdout)
        fflush(stderr)
        Foundation.signal(signal, SIG_DFL)
        kill(getpid(), signal)
        for _ in 0..<100 { usleep(10_000) } // up to 1 second, for delivery to a thread that doesn't block it
        _exit(128 + signal)
    }

    /// On `queue`.
    private func schedule(
        after delay: TimeInterval,
        repeating interval: TimeInterval? = nil,
        _ handler: @escaping () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + delay,
            repeating: interval.map { .nanoseconds(Int($0 * 1_000_000_000)) } ?? .never
        )
        timer.setEventHandler(handler: handler)
        timer.resume()
        timers.append(timer)
    }
}
