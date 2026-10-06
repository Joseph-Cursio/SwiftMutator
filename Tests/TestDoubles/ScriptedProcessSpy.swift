import Foundation
@testable import muterCore

/// A test command that plays `script` while it's waited for, as a real one runs: it writes its output
/// over time, and can run until it's killed. `terminateTree()` kills it: it stops where it is and dies of
/// SIGKILL, so its status is 9. When it exits it calls `terminationHandler`, as Foundation does once it
/// reaps a process. Several runs can use these at once, from any thread.
final class ScriptedProcessSpy: MuterProcess, @unchecked Sendable { // shared state is behind `lock`
    enum Step {
        /// Writes `text` to standard output `delay` seconds after the step before it.
        case write(String, after: TimeInterval)
        /// Runs until killed. Gives up after `deadline`, so a kill that never comes fails a test instead
        /// of hanging it.
        case runUntilKilled
        /// Dies of `signal` `delay` seconds after the step before it, as a process that a signal from outside
        /// SwiftMutator ends. The steps after it never play.
        case dieOf(signal: Int32, after: TimeInterval)
    }

    var processIdentifier: Int32 { 0 }
    var terminationStatus: Int32 { lock.withLock { status } }
    var terminationReason: Foundation.Process.TerminationReason { lock.withLock { reason } }
    // Set before the process runs, as a real process's are.
    var terminationHandler: (@Sendable (Foundation.Process) -> Void)?
    var environment: [String: String]?
    var arguments: [String]?
    var executableURL: URL?
    var currentDirectoryURL: URL?
    var standardOutput: Any?
    var standardError: Any?

    private let script: [Step]
    private let deadline: TimeInterval
    private let exitNoticedAfter: TimeInterval
    /// Signalled once for each kill.
    private let kills = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var status: Int32 = 0
    private var reason: Foundation.Process.TerminationReason = .exit
    private var waited = false
    private var killCount = 0

    /// `exitNoticedAfter` is how long after it exits `waitUntilExit()` returns: Foundation's notices an
    /// exit up to about 60 ms after it reaps the process.
    init(_ script: [Step], deadline: TimeInterval = 5, exitNoticedAfter: TimeInterval = 0) {
        self.script = script
        self.deadline = deadline
        self.exitNoticedAfter = exitNoticedAfter
    }

    var waitUntilExitCalled: Bool { lock.withLock { waited } }
    var terminateTreeCallCount: Int { lock.withLock { killCount } }

    func run() throws {}

    func waitUntilExit() {
        lock.withLock { waited = true }
        play()
        // This isn't a Foundation.Process, so the handler gets a stand-in.
        terminationHandler?(Foundation.Process())
        Thread.sleep(forTimeInterval: exitNoticedAfter)
    }

    /// Plays the script until it ends or the process is killed.
    private func play() {
        for step in script {
            switch step {
            case let .write(text, after: delay):
                guard !isKilled(within: delay) else { return }
                try? (standardOutput as? FileHandle)?.write(contentsOf: Data(text.utf8))
            case .runUntilKilled:
                guard !isKilled(within: deadline) else { return }
            case let .dieOf(signal, after: delay):
                guard !isKilled(within: delay) else { return }
                lock.withLock {
                    status = signal
                    reason = .uncaughtSignal
                }
                return
            }
        }
    }

    /// Whether the process is killed within `interval`. A killed process dies of SIGKILL.
    private func isKilled(within interval: TimeInterval) -> Bool {
        guard kills.wait(timeout: .now() + interval) == .success else { return false }
        lock.withLock {
            status = SIGKILL
            reason = .uncaughtSignal
        }
        return true
    }

    func terminateTree() {
        lock.withLock { killCount += 1 }
        kills.signal()
    }

    func runProcess(url: String, arguments args: [String]) -> Data? { nil }

    func terminate() {}

    func interrupt() {}
}
