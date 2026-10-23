@testable import muterCore
import XCTest

/// Those with a time limit run real processes, and kill every one they start however a test ends.
final class CommandResultTests: XCTestCase {
    private var directory: URL!
    private var launched: [Foundation.Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
        // Added after the folder's own teardown block, so it runs before that one.
        addTeardownBlock { [unowned self] in killEveryLaunchedProcess() }
    }

    // Through the protocol, as the coverage step runs it, so `Foundation.Process`'s own is the one run.
    func test_aCommand_givesItsExitStatus_andWhatItWroteToEachStream() {
        let process: MuterProcess = Foundation.Process()
        let result = process.runCommand(
            url: "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2; exit 3"]
        )

        XCTAssertEqual(result, CommandResult(status: 3, endedBySignal: false, output: "out\n", errors: "err\n"))
        XCTAssertEqual(result?.succeeded, false)
    }

    // Standard error can't fill a pipe and hold the command up while its standard output is read.
    func test_aCommand_thatWritesMuchToStandardError_stillEnds() {
        let result = Foundation.Process().runCommand(
            url: "/bin/sh",
            arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\\\0' x >&2; echo done"]
        )

        XCTAssertEqual(result?.output, "done\n")
        XCTAssertEqual(result?.errors.count, 1_000_000)
        XCTAssertEqual(result?.succeeded, true)
    }

    // Standard output is read while the command runs, so one that writes more than a pipe holds still ends. On a
    // thread of its own, so a command that never ends fails the test rather than hanging the suite.
    func test_aCommand_thatWritesMuchToStandardOutput_stillEnds() {
        let process = Foundation.Process()
        let ended = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: CommandResult?
        Thread.detachNewThread {
            result = process.runCommand(url: "/usr/bin/head", arguments: ["-c", "1000000", "/dev/zero"])
            ended.signal()
        }
        guard ended.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            return XCTFail("runCommand didn't end")
        }

        XCTAssertEqual(result?.output.utf8.count, 1_000_000)
        XCTAssertEqual(result?.succeeded, true)
    }

    func test_aCommandKilledByASignal_saysSo() {
        let result = Foundation.Process().runCommand(url: "/bin/sh", arguments: ["-c", "kill -9 $$"])

        XCTAssertEqual(result?.endedBySignal, true)
        XCTAssertEqual(result?.status, 9)
        XCTAssertEqual(result?.succeeded, false)
    }

    // `runProcess` hangs here: the pipe it reads stays open at this end.
    func test_aCommandThatCantBeStarted_givesNil_atOnce() {
        XCTAssertNil(Foundation.Process().runCommand(url: "/nonexistent/tool", arguments: []))
    }

    // MARK: - Time limit

    // Killed with every process it started, as `swift test`'s test processes would otherwise go on running. What it
    // printed before is kept. The sleep's odd length makes it easy to find if it's left behind.
    func test_aCommandPastItsTimeLimit_isKilled_withEveryProcessItStarted() throws {
        let started = Date()
        let result = runCommand("echo started; /bin/sleep 30.17 & echo $! > sleeper; wait", timeLimit: 0.5)

        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertEqual(result?.endedBySignal, true)
        XCTAssertEqual(result?.status, SIGKILL)
        XCTAssertEqual(result?.output, "started\n")
        XCTAssertEqual(result?.succeeded, false)
        let sleeper = try XCTUnwrap(pid(writtenTo: "sleeper"))
        XCTAssertTrue(waitUntil(within: 2) { isGone(sleeper) }, "the command's child is still running")
    }

    func test_aCommandWithinItsTimeLimit_endsAsWithoutOne() {
        let result = runCommand("echo out; echo err >&2; exit 3", timeLimit: 30)

        XCTAssertEqual(result, CommandResult(status: 3, endedBySignal: false, output: "out\n", errors: "err\n"))
        XCTAssertEqual(result?.timedOut, false)
    }

    // A process whose parent exited before the kill escapes it, and holds standard output open for as long as it runs.
    // After the kill, the output is waited for only briefly.
    func test_aCommandPastItsTimeLimit_ends_evenIfAProcessThatEscapedTheKillHoldsItsOutput() throws {
        let started = Date()
        let result = runCommand(
            "echo started; (/bin/sleep 30.18 & echo $! > escaped); /bin/sleep 30.19",
            timeLimit: 0.5
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(result?.timedOut, true)
        XCTAssertEqual(result?.output, "started\n")
        // Only the teardown, which kills the command's process group, ends it.
        let escaped = try XCTUnwrap(pid(writtenTo: "escaped"))
        XCTAssertFalse(isGone(escaped), "nothing escaped the kill")
    }

    // Even one that exited just as it was killed.
    func test_aCommandThatTimedOut_didntSucceed() {
        XCTAssertFalse(CommandResult(status: 0, endedBySignal: false, output: "", errors: "", timedOut: true).succeeded)
    }

    // MARK: - Helpers

    /// `script` run by `/bin/sh` in this test's folder, under `timeLimit`. On a thread of its own, so a command that
    /// is never killed fails the test rather than hanging the suite.
    private func runCommand(_ script: String, timeLimit: TimeInterval) -> CommandResult? {
        let process = Foundation.Process()
        process.currentDirectoryURL = directory
        launched.append(process)
        let ended = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: CommandResult?
        Thread.detachNewThread {
            result = process.runCommand(url: "/bin/sh", arguments: ["-c", script], timeLimit: timeLimit)
            ended.signal()
        }
        guard ended.wait(timeout: .now() + 10) == .success else {
            XCTFail("runCommand didn't end")
            return nil
        }
        return result
    }

    /// Kills each launched process's process group until no process is left in it. Foundation.Process
    /// starts each launched process in a group of its own, and a shell's background jobs stay in it. A
    /// group found empty is never signalled again: the system may give its ID to another process.
    private func killEveryLaunchedProcess() {
        var groups = Set(launched.map(\.processIdentifier).filter { $0 > 1 }) // kill(-1) signals everything
        let groupsEmptied = waitUntil(within: 5) {
            groups = groups.filter { kill(-$0, SIGKILL) == 0 || errno != ESRCH }
            return groups.isEmpty
        }
        XCTAssertTrue(groupsEmptied, "processes are left in the process groups \(groups.sorted())")
    }

    private func pid(writtenTo name: String) -> Int32? {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether no process has this ID.
    private func isGone(_ pid: Int32) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Polls `condition` until it holds or `timeout` seconds pass, and returns whether it held.
    private func waitUntil(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
