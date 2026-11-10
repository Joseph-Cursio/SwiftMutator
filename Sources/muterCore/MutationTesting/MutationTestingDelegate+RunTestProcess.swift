#if os(Linux)
import Glibc
#else
import Darwin.C
#endif
import Foundation

extension MutationTestingDelegate {
    func runTestProcess(
        _ process: Process,
        logFileUrl: URL,
        withTimeout timeout: TimeInterval?,
        stoppingAtFirstFailure: Bool,
        failedTestLinesAreReliable: Bool
    ) async throws -> TestRun {
        let ending = TestRunEnding()
        let follower = stoppingAtFirstFailure ? TestLogFollower(logFileUrl: logFileUrl) : nil
        let locker = mutatedProjectLocker
        let run: @Sendable () async throws -> TestingExecutionResult = {
            try await Self.runToExit(process, follower: follower, ending: ending, recordingIn: locker)
            return .success
        }
        if let timeout {
            _ = try await testingTimeOutExecutor().withTimeLimit(timeout, run) {
                // Kill the whole process tree, not just the launched command — see terminateTree(). Only if
                // nothing ended the run first: its process may have just exited, or been stopped at a failed test.
                if ending.recordTimeLimit(of: process) { process.terminateTree() }
                return .timeout
            }
        } else {
            _ = try await run()
        }

        // A signal from outside SwiftMutator (killall, logout, a supervisor stopping the whole tree) can end the test
        // command milliseconds before SwiftMutator's own signal stops mutation testing; the run would be recorded
        // first, as a crash, which counts as killed. Only a run that seems to have died of such a signal waits:
        // SwiftMutator's own kills end a run for another reason. A cancellation in the wait throws, and the run reads
        // as cancelled.
        let exit = ending.exit(of: process)
        if ending.reason == .exited, Self.mayHaveEndedByAnOutsideSignal(exit) {
            try await sleep(Self.outsideSignalWait)
        }

        // withTimeLimit returns whichever of its tasks finishes first, which needn't be what ended the run.
        let executionResult = try ending.executionResult()
        // Decoded leniently: the log is whatever the test command wrote, and a run stopped at the time
        // limit, or a test process that crashed mid-write, can end partway through a character. Strict
        // decoding threw on that, and the run was reported as a build error, outside the score.
        var testExecutionLog = try String(lossyUTF8: Data(contentsOf: logFileUrl))
        // Read back, the file stays: whatever records the run moves it to its log's kept name, or removes it.
        let testResult = TestSuiteOutcome.from(
            testLog: testExecutionLog,
            terminationStatus: exit.status,
            timeoutExecution: executionResult,
            failedTestLinesAreReliable: failedTestLinesAreReliable
        )
        let note: String? = switch ending.reason {
        case let .failedTest(line): Self.noteForRunStopped(at: line, after: testExecutionLog)
        case let .crashed(line): Self.noteForRunStopped(atCrash: line, after: testExecutionLog)
        default: nil
        }
        if let note {
            testExecutionLog += note
            // The file the log is kept from ends as the log does. Its process tree was killed, so nothing writes to it.
            Self.append(note, to: logFileUrl)
        }

        let endedBy = TestRun.Ending(ending.reason)
        return TestRun(
            outcome: testResult,
            testLog: testExecutionLog,
            ending: endedBy,
            exitStatus: endedBy == .exited ? exit.status : nil
        )
    }

    /// Launches `process` and waits for it to exit. With a follower, stops it at the first failed test or crash its
    /// log shows. Cancelling the calling task kills the process tree: waiting ignores cancellation, so the
    /// run would otherwise go on until its tests ended. While it runs, it is recorded in the mutated project's
    /// lock, so that if SwiftMutator dies first, killed or crashed, it is killed too (see `MutatedProjectLock`).
    static func runToExit(
        _ process: Process,
        follower: TestLogFollower?,
        ending: TestRunEnding,
        recordingIn locker: MutatedProjectLocking
    ) async throws {
        // Foundation calls this as soon as it reaps the process, which can be before `run()` returns. The exit is
        // recorded first, so neither the follower nor the time limit kills a process that has exited, and reports a
        // run that ended by itself as stopped. Waiting for the handler holds no thread, unlike `waitUntilExit()`, which
        // also notices the exit up to about 60 ms later. On Linux the kernel's report of the exit can come long before.
        let exited = Latch()
        process.terminationHandler = ending.recordingExit(opening: exited)
        try process.runWithNoSignalBlocked()
        process.watchForExit(recordingIn: ending, opening: exited)
        locker.testProcessStarted(process.processIdentifier)
        defer { locker.testProcessEnded(process.processIdentifier) }
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                if let follower {
                    group.addTask {
                        guard let stop = await follower.firstStop(), ending.record(stop) else { return }
                        process.terminateTree()
                    }
                }
                await exited.wait()
                // Stops the follower if it is still watching. The group waits for it, so it never outlives the run.
                group.cancelAll()
            }
        } onCancel: {
            if ending.record(.cancelled) {
                process.terminateTreeInBackground()
            }
        }
        // A kill finds its processes by listing the tree, which misses a test process the shell was starting as the
        // stop came, and one whose parent has ended. It would run on until its tests ended, reading later mutants'
        // active-mutant file, or for good if they hang. Each is still in the shell's group, and the shell, now ended,
        // starts no more. Side by side, killing at random moments in a run's first 400 ms, 51 of 34,213 kills left a
        // helper without this, and none of 34,191 with it. A helper of `swift test` leads its own group, so there this
        // finds only what `swift test` itself left.
        if ending.wasKilled { process.killProcessGroup() }
    }

    /// How long a run that may have ended by a signal from outside waits before it is recorded. Measured: a run is
    /// recorded 1–65 ms after its test process dies, and with SwiftMutator signalled 5–50 ms after the test process,
    /// 8 of 15 such runs were recorded as killed.
    static let outsideSignalWait: UInt64 = 250_000_000

    /// Whether a test process that ended as `exit` says may have ended by a stopping signal sent from outside
    /// SwiftMutator: SIGINT, SIGTERM or SIGHUP. An ordinary test failure exits 1, a crash dies of another signal, and
    /// SwiftMutator's own SIGKILL ends a run for another reason, so none of them wait.
    static func mayHaveEndedByAnOutsideSignal(_ exit: ProcessExit) -> Bool {
        switch exit.reason {
        case .uncaughtSignal:
            return [SIGINT, SIGTERM, SIGHUP].contains(exit.status)

        // swiftly's proxy, and shells, pass a child's signal on as its number or 128 + it.
        case .exit:
            return [2, 15, 129, 130, 143].contains(exit.status)

        @unknown default:
            return false
        }
    }

    /// The note that ends a stopped run's log: why it ends there, and the line that stopped it. Appended after
    /// the run is classified, so it can't change the outcome. Its lines start with `[SwiftMutator]`, so
    /// `FailedTestLine` doesn't match them if the log is read again.
    static func noteForRunStopped(at failedTestLine: String, after log: String) -> String {
        note(
            stopped: "at its first failed test (stopAtFirstFailure); the tests after it",
            at: failedTestLine,
            after: log
        )
    }

    /// The note that ends the log of a run stopped at a crash, as `noteForRunStopped(at:after:)` does.
    static func noteForRunStopped(atCrash crashLine: String, after log: String) -> String {
        note(stopped: "at a crash (stopAtFirstFailure); the test bundles after it", at: crashLine, after: log)
    }

    /// Appends `note` to the file at `url`. One that can't be written to keeps the log it has: the run's `testLog`
    /// still ends with the note.
    static func append(_ note: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(note.utf8))
    }

    static func note(stopped how: String, at line: String, after log: String) -> String {
        // The run was killed wherever its output was, often partway through a line.
        let lineBreak = log.isEmpty || log.hasSuffix("\n") ? "" : "\n"
        return lineBreak + """

            [SwiftMutator] Stopped this test run \(how) did not run.
            [SwiftMutator] The line that stopped it: \(line)

            """
    }
}
