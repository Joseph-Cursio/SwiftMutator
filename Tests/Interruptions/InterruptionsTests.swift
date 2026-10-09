@testable import muterCore
import XCTest

/// `Interruptions` with `SignalObserverFake` and stand-ins for killing SwiftMutator's descendants, for exiting and for
/// standard error, so that no test signals, kills or ends the test runner. The acceptance tests send real signals to a
/// SwiftMutator they start.
final class InterruptionsTests: MuterTestCase {
    private var observer = SignalObserverFake()
    /// What the stand-ins were asked to do, in order: "killed" for each kill of the descendants, and "exited by …".
    private let events = Events()
    /// What `Interruptions` said on standard error.
    private let said = Events()
    /// Opens when the stand-in for exiting is called, where SwiftMutator would have ended.
    private let exited = Gate()

    // MARK: - InterruptionRecord

    func test_recordsOnlyTheFirstSignal() {
        let record = InterruptionRecord()

        XCTAssertNil(record.signal)
        XCTAssertTrue(record.record(SIGTERM))
        XCTAssertFalse(record.record(SIGINT))
        XCTAssertEqual(record.signal, SIGTERM)
    }

    func test_namesTheSignals() {
        XCTAssertEqual(InterruptionRecord.name(of: SIGINT), "SIGINT")
        XCTAssertEqual(InterruptionRecord.name(of: SIGTERM), "SIGTERM")
        XCTAssertEqual(InterruptionRecord.name(of: SIGHUP), "SIGHUP")
        XCTAssertEqual(InterruptionRecord.name(of: SIGUSR1), "signal \(SIGUSR1)")
    }

    // MARK: - Interruptions

    func test_withoutASignal_returnsTheWorksResult_andStopsObserving() throws {
        let running = Running(makeInterruptions()) { throw WorkError() }

        let ended = try XCTUnwrap(running.wait())

        XCTAssertNil(ended.signal)
        XCTAssertThrowsError(try ended.result.get()) { XCTAssertTrue($0 is WorkError, "\($0)") }
        XCTAssertEqual(observer.observed, [SIGINT, SIGTERM, SIGHUP])
        XCTAssertTrue(observer.stopped, "each signal has its earlier disposition back")
        XCTAssertEqual(events.all, [])
        XCTAssertEqual(said.all, [])
        XCTAssertNil(current.interruption.signal)
    }

    // Every run under way then records itself cancelled before anything kills its process, so no run that stopping
    // ended is recorded as a mutant's result.
    func test_theFirstSignal_cancelsTheWork_beforeKillingDescendants() throws {
        let started = Gate()
        let events = events
        let running = Running(makeInterruptions()) {
            try await withTaskCancellationHandler {
                started.open()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } onCancel: {
                events.append("cancelled")
            }
        }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGINT))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(ended.signal, SIGINT)
        XCTAssertThrowsError(try ended.result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        // The last kill comes once the work has ended, for whatever started after the one before it.
        XCTAssertEqual(events.all, ["cancelled", "killed", "killed"])
        XCTAssertFalse(observer.stopped, "a second signal must still stop SwiftMutator at once")
    }

    // The end line names the signal, and the work reads it as soon as it sees the cancellation.
    func test_theSignalIsRecorded_beforeTheWorkIsCancelled() throws {
        let started = Gate()
        let events = events
        let running = Running(makeInterruptions()) {
            try await withTaskCancellationHandler {
                started.open()
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } onCancel: {
                events.append(current.interruption.signal.map(InterruptionRecord.name(of:)) ?? "no signal")
            }
        }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGTERM))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(events.all.first, "SIGTERM")
        XCTAssertEqual(current.interruption.signal, SIGTERM)
    }

    func test_aSecondSignal_killsDescendants_andExitsByTheFirst() throws {
        let exited = exited
        // Work that ignores cancellation, as an in-process copy of the project does.
        let running = Running(makeInterruptions()) { exited.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGTERM))
        XCTAssertTrue(observer.send(SIGINT))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(Array(events.all.prefix(3)), ["killed", "killed", "exited by SIGTERM"])
        XCTAssertEqual(ended.signal, SIGTERM)
        XCTAssertEqual(said.all.last, "⏹ Stopping at once. SwiftMutator removes worker copies it leaves behind when it next runs.")
    }

    // When its terminal closes, zsh sends the job SIGHUP twice, about a millisecond apart. Nobody is left to ask for a
    // stop at once, so the second must not cut the stop short: the grace period still bounds it.
    func test_aRepeatedHangup_isIgnored_butAnotherSignalStillStopsAtOnce() throws {
        let exited = exited
        // Work that ignores cancellation, so that only exiting ends it.
        let running = Running(makeInterruptions()) { exited.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGHUP))
        XCTAssertTrue(observer.send(SIGHUP))

        XCTAssertEqual(events.all, ["killed"], "the repeated hangup neither kills again nor exits")
        XCTAssertEqual(said.all, [Interruptions.stoppingMessage(for: SIGHUP)])

        XCTAssertTrue(observer.send(SIGTERM))
        let ended = try XCTUnwrap(running.wait())

        XCTAssertEqual(Array(events.all.prefix(3)), ["killed", "killed", "exited by SIGHUP"])
        XCTAssertEqual(ended.signal, SIGHUP)
    }

    func test_afterTheGracePeriod_killsDescendants_andExitsBySignal() throws {
        let exited = exited
        let running = Running(makeInterruptions(gracePeriod: 0.05)) { exited.wait() }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGINT))
        let ended = try XCTUnwrap(running.wait(within: 2))

        XCTAssertEqual(Array(events.all.prefix(3)), ["killed", "killed", "exited by SIGINT"])
        XCTAssertEqual(ended.signal, SIGINT)
        XCTAssertEqual(said.all.count, 2)
        XCTAssertTrue(said.all.last?.contains("so it is stopping at once") == true, "\(said.all)")
    }

    // Steps start processes one after another, and no cancellation reaches the ones that block: killing one would only
    // let the next start.
    func test_afterTheFirstSignal_killsDescendantsUntilTheWorkEnds() throws {
        let events = events
        let running = Running(makeInterruptions(sweepInterval: 0.01)) {
            _ = Self.waitUntil(within: 5) { events.count(of: "killed") >= 4 }
        }
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGINT))
        _ = try XCTUnwrap(running.wait())
        let killsUntilItEnded = events.count(of: "killed")
        Thread.sleep(forTimeInterval: 0.1)

        XCTAssertGreaterThanOrEqual(killsUntilItEnded, 4)
        XCTAssertEqual(events.count(of: "killed"), killsUntilItEnded, "no kill once the work has ended")
    }

    func test_saysItIsStopping_andHowToStopAtOnce() throws {
        let started = Gate()
        let running = Running(makeInterruptions()) {
            started.open()
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGHUP))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(said.all, [Interruptions.stoppingMessage(for: SIGHUP)])
        XCTAssertEqual(
            Interruptions.stoppingMessage(for: SIGINT),
            "⏹ Stopping (SIGINT): ending the test runs under way and keeping what was tested. "
                + "Press Ctrl-C again to stop at once.\n\n"
        )
        let terminate = Interruptions.stoppingMessage(for: SIGTERM)
        XCTAssertTrue(terminate.hasPrefix("⏹ Stopping (SIGTERM): "), terminate)
        XCTAssertTrue(terminate.contains("Send another SIGINT, SIGTERM or SIGHUP to stop at once."), terminate)
        XCTAssertFalse(terminate.contains("Ctrl-C"), terminate)
        // A second SIGHUP doesn't stop at once, so it isn't offered.
        let hangup = Interruptions.stoppingMessage(for: SIGHUP)
        XCTAssertTrue(hangup.hasPrefix("⏹ Stopping (SIGHUP): "), hangup)
        XCTAssertTrue(hangup.contains("Send SIGINT or SIGTERM to stop at once."), hangup)
    }

    // Without a terminal there's no progress bar to leave room for, so a log gets no empty lines after the message.
    func test_withoutATerminal_theStoppingMessage_hasNoEmptyLinesAfterIt() throws {
        current.standardOutIsATerminal = false
        let started = Gate()
        let running = Running(makeInterruptions()) {
            started.open()
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        XCTAssertTrue(started.wait())
        waitUntilObserving()

        XCTAssertTrue(observer.send(SIGHUP))
        _ = try XCTUnwrap(running.wait())

        XCTAssertEqual(said.all, [
            "⏹ Stopping (SIGHUP): ending the test runs under way and keeping what was tested. "
                + "Send SIGINT or SIGTERM to stop at once.",
        ])
    }

    // `nohup` ignores SIGHUP, so that a run outlives its terminal.
    func test_aSignalIgnoredAtStart_neverStopsTheWork() throws {
        observer = SignalObserverFake(ignoredAtStart: [SIGHUP])
        let finish = Gate()
        let running = Running(makeInterruptions()) { finish.wait() }
        waitUntilObserving()

        XCTAssertFalse(observer.send(SIGHUP))
        finish.open()
        let ended = try XCTUnwrap(running.wait())

        XCTAssertNil(ended.signal)
        XCTAssertEqual(observer.observed, [SIGINT, SIGTERM])
        XCTAssertEqual(events.all, [])
        XCTAssertEqual(said.all, [])
    }

    // MARK: - Helpers

    /// Long grace periods and sweep intervals by default, so that only a test about them sees them.
    private func makeInterruptions(gracePeriod: TimeInterval = 60, sweepInterval: TimeInterval = 60) -> Interruptions {
        let events = events
        let said = said
        let exited = exited
        return Interruptions(
            observer: observer,
            killDescendants: { events.append("killed") },
            exit: { signal in
                events.append("exited by \(InterruptionRecord.name(of: signal))")
                exited.open()
            },
            say: { said.append($0) },
            gracePeriod: gracePeriod,
            sweepInterval: sweepInterval
        )
    }

    /// A signal sent before `run` observes signals goes nowhere.
    private func waitUntilObserving(file: StaticString = #filePath, line: UInt = #line) {
        let observer = observer
        XCTAssertTrue(Self.waitUntil(within: 5) { !observer.observed.isEmpty }, "never observed", file: file, line: line)
    }

    /// Polls `condition` until it holds or `timeout` seconds pass, and returns whether it held.
    private static func waitUntil(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }
}

private struct WorkError: Error {}

/// Strings appended from any thread, in order.
private final class Events: @unchecked Sendable { // `list` is behind `lock`
    private let lock = NSLock()
    private var list: [String] = []

    var all: [String] { lock.withLock { list } }

    func append(_ event: String) {
        lock.withLock { list.append(event) }
    }

    func count(of event: String) -> Int {
        all.filter { $0 == event }.count
    }
}

/// Opened from any thread; once open, it stays open.
private final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func open() {
        semaphore.signal()
    }

    /// Blocks until the gate is open, at most `timeout` seconds, and returns whether it opened.
    @discardableResult
    func wait(within timeout: TimeInterval = 5) -> Bool {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
        semaphore.signal() // for the next wait
        return true
    }
}

/// `Interruptions.run` under way in a task of its own, so that a test can send signals meanwhile. Every work a test
/// runs ends within seconds, however the test goes.
private final class Running: @unchecked Sendable { // `ended` is written before `finished` opens, and read after
    private let finished = Gate()
    private var ended: Interruptions.Ended?

    init(_ interruptions: Interruptions, _ work: @escaping @Sendable () async throws -> Void) {
        Task.detached { [self] in
            ended = await interruptions.run(work)
            finished.open()
        }
    }

    /// How the run ended, or nil if it hasn't within `timeout` seconds.
    func wait(within timeout: TimeInterval = 5) -> Interruptions.Ended? {
        finished.wait(within: timeout) ? ended : nil
    }
}
