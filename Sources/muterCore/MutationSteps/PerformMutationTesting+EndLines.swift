import Foundation

/// The end line of a session that is stopped at once.
extension PerformMutationTesting {
    /// How long stopping at once waits to write the end line while a line is being written, in seconds.
    static let endLineWaitAtOnce: TimeInterval = 2

    /// Writes the end line of an interrupted session, from the thread that stops SwiftMutator at once, by a second
    /// signal, Ctrl-\ or the grace period: mutation testing never gets to write its own. Static, so that thread is
    /// given the session and the two dependencies it reads, not the step.
    static func endResultsAtOnce(of session: TestingSession, stoppedBy interruption: InterruptionRecord, now: Now) {
        session.end(waitingAtMost: endLineWaitAtOnce) { recorded in
            let detail = interruption.signal.map(InterruptionRecord.name(of:))
            let testDuration = now().timeIntervalSince(session.startedAt)
            return ResultsEnd(
                session: session.number,
                endedAt: now(),
                reason: .interrupted,
                detail: detail,
                testDurationSeconds: testDuration,
                recorded: recorded
            )
        }
    }
}
