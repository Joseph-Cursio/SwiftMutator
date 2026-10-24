import Foundation

/// The signal that stopped this run, if one did, and what to do before SwiftMutator stops at once. `Interruptions`
/// records the signal before it cancels the run, so that the end line can name it.
final class InterruptionRecord: @unchecked Sendable { // `first` and `atOnce` are behind `lock`
    private let lock = NSLock()
    private var first: Int32?
    private var atOnce: (@Sendable () -> Void)?

    /// The first stopping signal, or nil if none came.
    var signal: Int32? { lock.withLock { first } }

    /// Sets what stopping at once does before SwiftMutator ends, or with nil, that it does nothing: mutation testing
    /// writes its end line while its results file is open.
    func beforeStoppingAtOnce(_ action: (@Sendable () -> Void)?) {
        lock.withLock { atOnce = action }
    }

    /// Does what `beforeStoppingAtOnce` set, if anything, on the thread that stops SwiftMutator at once.
    func stoppingAtOnce() {
        lock.withLock { atOnce }?()
    }

    /// Records `signal` unless one was recorded before, and returns whether it did.
    func record(_ signal: Int32) -> Bool {
        lock.withLock {
            guard first == nil else { return false }
            first = signal
            return true
        }
    }

    static func name(of signal: Int32) -> String {
        [SIGINT: "SIGINT", SIGTERM: "SIGTERM", SIGHUP: "SIGHUP", SIGQUIT: "SIGQUIT"][signal] ?? "signal \(signal)"
    }
}

/// Runs a command's work so that SIGINT, SIGTERM and SIGHUP stop it cleanly, SIGQUIT at once, and SIGTSTP suspends
/// it. Each process SwiftMutator starts leads a process group of its own, so a terminal's Ctrl-C or Ctrl-Z reaches
/// SwiftMutator alone, and stopping or suspending them is up to it.
final class Interruptions: @unchecked Sendable { // `timers` is touched only on `queue`
    static let stoppingSignals = [SIGINT, SIGTERM, SIGHUP]
    /// Ctrl-\ sends SIGQUIT, whose default action, as a SIGKILL does, would leave test processes running, and no end
    /// line. Ctrl-Z sends SIGTSTP, whose default action would suspend SwiftMutator while its tests ran on: once it
    /// continued, every time limit that had passed would fire at once, even for tests that had ended.
    static let observedSignals = stoppingSignals + [SIGQUIT, SIGTSTP]

    /// How the work ended, and the signal that stopped it, if one came while it ran.
    struct Ended {
        let result: Result<Void, Error>
        let signal: Int32?
    }

    @Dependency(\.interruption)
    private var record: InterruptionRecord
    @Dependency(\.standardOutIsATerminal)
    private var standardOutIsATerminal: Bool
    @Dependency(\.suspensions)
    private var suspensions: Suspensions
    private let observer: SignalObserving
    private let killDescendants: @Sendable () -> Void
    private let suspend: @Sendable () -> Void
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
        suspend: @escaping @Sendable () -> Void = { ProcessTree.suspendThisProcessAndItsDescendants() },
        exit: @escaping @Sendable (Int32) -> Void = { Interruptions.exit(by: $0) },
        say: @escaping @Sendable (String) -> Void = { fputs($0 + "\n", stderr) },
        gracePeriod: TimeInterval = 30,
        sweepInterval: TimeInterval = 0.25
    ) {
        self.observer = observer
        self.killDescendants = killDescendants
        self.suspend = suspend
        self.exit = exit
        self.say = say
        self.gracePeriod = gracePeriod
        self.sweepInterval = sweepInterval
    }

    /// Runs `work` until it ends. The first stopping signal cancels it, kills every process SwiftMutator started, and
    /// keeps killing new ones until `work` ends; a second signal, other than a SIGHUP after a first SIGHUP, or
    /// `gracePeriod` seconds without `work` ending, ends SwiftMutator at once, by the first signal. So does a SIGQUIT,
    /// first or not. Once a signal came, the caller is to exit by it, which a second signal meanwhile still does at
    /// once.
    func run(_ work: @escaping @Sendable () async throws -> Void) async -> Ended {
        let task = Task { try await work() }
        observer.start(observing: Self.observedSignals, on: queue) { [self] signal in
            if signal == SIGTSTP {
                suspendUnlessStopping()
            } else {
                received(signal, stopping: task)
            }
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
            stopAtOnce(by: record.signal ?? signal)
            return
        }
        guard signal != SIGQUIT else { return stopAtOnce(by: signal) }
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
            stopAtOnce(
                by: signal,
                saying: "⏹ SwiftMutator hasn't stopped after \(Int(gracePeriod)) seconds, so it is stopping at once."
            )
        }
    }

    /// On `queue`, which waits here while SwiftMutator is suspended: a signal meanwhile is handled once it continues.
    /// No time limit counts the time suspended. A run that is stopping isn't suspended: it is about to end, and its
    /// grace period would count the time.
    private func suspendUnlessStopping() {
        guard record.signal == nil else { return }
        suspensions.begin()
        suspend()
        suspensions.end()
    }

    /// On `queue`. Kills every process SwiftMutator started, has mutation testing write its end line, and ends
    /// SwiftMutator by `signal`, whatever the work is doing.
    private func stopAtOnce(
        by signal: Int32,
        saying message: String = "⏹ Stopping at once. "
            + "SwiftMutator removes worker copies it leaves behind when it next runs."
    ) {
        killDescendants()
        // Before saying anything: a standard error nobody reads could hold it up.
        record.stoppingAtOnce()
        say(message)
        exit(signal)
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
    /// a script or loop running it stops too. Raised on this thread once it no longer blocks the signal, as a Dispatch
    /// thread does: blocked, `raise()` left the signal pending, and the fallback ran instead in 44 of 45 lab runs. Sent
    /// to the process alone, on Linux SIGQUIT went to libdispatch's signalfd, and the fallback ran in 20 of 20.
    static func exit(by signal: Int32) -> Never {
        fflush(stdout)
        fflush(stderr)
        Foundation.signal(signal, SIG_DFL)
        var unblocking = sigset_t()
        sigemptyset(&unblocking)
        sigaddset(&unblocking, signal)
        pthread_sigmask(SIG_UNBLOCK, &unblocking, nil)
        raise(signal)
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
