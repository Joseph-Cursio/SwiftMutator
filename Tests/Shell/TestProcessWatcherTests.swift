@testable import muterCore
import XCTest

/// These run real processes, and kill every one they start however a test ends.
final class TestProcessWatcherTests: XCTestCase {
    private var directory: URL!
    private var launched: [Foundation.Process] = []
    /// Descendants a test started that may still be running.
    private var unconfirmedGone: Set<Int32> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
    }

    override func tearDownWithError() throws {
        unconfirmedGone.forEach { kill($0, SIGKILL) }
        for process in launched where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        XCTAssertTrue(waitUntil(within: 5) { !self.launched.contains(where: \.isRunning) })
        try super.tearDownWithError()
    }

    func test_whenThePipeCloses_theWatcherKillsEachTestProcessStillRunning_withEveryProcessItStarted() throws {
        let (sut, watching) = try watchInThisProcess()
        let tree = try launchTree()
        sut.started(try XCTUnwrap(RecordedProcess(tree.root.processIdentifier)))

        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(tree.root.isRunning, "killed while SwiftMutator still ran")
        sut.close()

        XCTAssertEqual(watching.wait(timeout: .now() + 5), .success, "the watcher didn't end")
        XCTAssertTrue(waitUntil(within: 2) { tree.everyProcess.allSatisfy(self.isGone) }, "still running")
    }

    // Its ID may have gone to another process. Here it is still running, so that killing it would show.
    func test_aTestProcessThatHasEnded_isLeftAlone() throws {
        let (sut, watching) = try watchInThisProcess()
        let ended = try launchTree()
        let running = try launchTree()
        sut.started(try XCTUnwrap(RecordedProcess(ended.root.processIdentifier)))
        sut.started(try XCTUnwrap(RecordedProcess(running.root.processIdentifier)))
        sut.ended(ended.root.processIdentifier)

        sut.close()

        XCTAssertEqual(watching.wait(timeout: .now() + 5), .success, "the watcher didn't end")
        XCTAssertTrue(waitUntil(within: 2) { running.everyProcess.allSatisfy(self.isGone) }, "still running")
        XCTAssertTrue(staysRunning(ended.everyProcess), "a process that had ended was killed")
    }

    // Its ID may have gone to another process, which must not be killed.
    func test_aProcessThatStartedAtAnotherTime_isLeftAlone() throws {
        let (sut, watching) = try watchInThisProcess()
        let tree = try launchTree()
        let started = try XCTUnwrap(MutatedProjectLock.startTime(of: tree.root.processIdentifier))
        sut.started(RecordedProcess(id: tree.root.processIdentifier, started: started - 1))

        sut.close()

        XCTAssertEqual(watching.wait(timeout: .now() + 5), .success, "the watcher didn't end")
        XCTAssertTrue(staysRunning(tree.everyProcess), "another process was killed")
    }

    // SwiftMutator's own executable, as `swift-mutator watch-test-processes`. SwiftMutator's exit closes the pipe, as
    // closing it here does. The watcher leads a process group of its own, but a Ctrl-C or a hangup can still reach it.
    func test_theWatcherSwiftMutatorStarts_outlivesACtrlCAndAHangup_andKillsItsTestProcessesWhenThePipeCloses() throws {
        let executable = try swiftMutatorExecutable()
        let sut = try XCTUnwrap(TestProcessWatcher.start(executable: executable))
        let watcher = try XCTUnwrap(sut.process)
        launched.append(watcher)
        let tree = try launchTree()
        sut.started(try XCTUnwrap(RecordedProcess(tree.root.processIdentifier)))
        XCTAssertNotEqual(getpgid(watcher.processIdentifier), getpgrp())
        // Once it has started up: the signals that would end it before then can't reach its process group.
        XCTAssertTrue(
            waitUntil(within: 10) { self.ignores([SIGINT, SIGHUP], process: watcher.processIdentifier) },
            "the watcher doesn't ignore SIGINT and SIGHUP"
        )

        kill(watcher.processIdentifier, SIGINT)
        kill(watcher.processIdentifier, SIGHUP)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(watcher.isRunning, "a Ctrl-C or a hangup ended the watcher")
        XCTAssertTrue(tree.root.isRunning, "killed while SwiftMutator still ran")
        sut.close()

        XCTAssertTrue(waitUntil(within: 5) { tree.everyProcess.allSatisfy(self.isGone) }, "still running")
        XCTAssertTrue(waitUntil(within: 5) { !watcher.isRunning }, "the watcher didn't end")
        XCTAssertEqual(watcher.terminationReason, .exit)
        XCTAssertEqual(watcher.terminationStatus, 0)
    }

    // A process that held the pipe open would keep the watcher waiting until it ended. Foundation.Process closes what a
    // process it starts would inherit, but posix_spawn, as this test uses, doesn't.
    func test_noProcessStartedWhileThePipeIsOpen_holdsIt() throws {
        let (sut, watching) = try watchInThisProcess()
        let child = try spawn("/bin/sleep", "61.52")
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }

        sut.close()

        XCTAssertEqual(watching.wait(timeout: .now() + 5), .success, "a process started meanwhile holds the pipe open")
    }

    func test_theWatcherIsNotListedInHelp() {
        XCTAssertFalse(MuterCommand.helpMessage().contains("watch-test-processes"), MuterCommand.helpMessage())
    }

    // MARK: - Helpers

    /// A watcher running on a thread of this process, as `swift-mutator watch-test-processes` runs, and what is
    /// signalled when it ends.
    private func watchInThisProcess() throws -> (TestProcessWatcher, DispatchSemaphore) {
        let ends = try XCTUnwrap(TestProcessWatcher.makePipe())
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TestProcessWatcher.watch(readingFrom: ends.read)
            close(ends.read)
            ended.signal()
        }
        return (TestProcessWatcher(writingTo: ends.write), ended)
    }

    /// The `swift-mutator` executable built beside these tests. Skips the test if it isn't there.
    private func swiftMutatorExecutable() throws -> URL {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("swift-mutator")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "this test needs swift-mutator built beside the tests, at \(executable.path)"
        )
        return executable
    }

    /// A real process tree, as a test command starts: `sh`, the root, starts a `sleep`.
    private struct Tree {
        let root: Foundation.Process
        let sleeper: Int32

        var everyProcess: [Int32] { [root.processIdentifier, sleeper] }
    }

    /// Starts a `Tree`, with the real process factory. The shell writes down the ID of the sleep, so a test knows every
    /// process without listing them. The sleep's odd length makes any process left behind easy to find.
    private func launchTree(file: StaticString = #filePath, line: UInt = #line) throws -> Tree {
        let root = try XCTUnwrap(MuterProcessFactory.makeProcess() as? Foundation.Process, file: file, line: line)
        let name = UUID().uuidString
        root.executableURL = URL(fileURLWithPath: "/bin/sh")
        root.arguments = ["-c", "/bin/sleep 61.51 & echo $! > \(name); wait"]
        root.currentDirectoryURL = directory
        try root.run()
        launched.append(root)

        var sleeper: Int32?
        _ = waitUntil(within: 2) {
            sleeper = (try? String(contentsOf: self.directory.appendingPathComponent(name), encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return sleeper != nil
        }
        let pid = try XCTUnwrap(sleeper, file: file, line: line)
        unconfirmedGone.insert(pid)
        return Tree(root: root, sleeper: pid)
    }

    /// Whether `process` ignores every one of `signals`.
    private func ignores(_ signals: [Int32], process: Int32) -> Bool {
        #if os(macOS)
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        let ignored = UInt64(info.kp_proc.p_sigignore)
        #else
        // proc(5): "SigIgn", a mask in hexadecimal.
        guard let status = try? String(contentsOfFile: "/proc/\(process)/status", encoding: .utf8),
              let line = status.split(separator: "\n").first(where: { $0.hasPrefix("SigIgn:") }),
              let ignored = UInt64(line.dropFirst("SigIgn:".count).trimmingCharacters(in: .whitespaces), radix: 16)
        else { return false }
        #endif
        return signals.allSatisfy { ignored & (1 << UInt64($0 - 1)) != 0 }
    }

    /// Whether no process has this ID, or only one that has ended and waits to be reaped. Once a process is gone, it
    /// is never killed again: the system may give its ID to another process.
    private func isGone(_ pid: Int32) -> Bool {
        guard MutatedProjectLock.startTime(of: pid) == nil else { return false }
        unconfirmedGone.remove(pid)
        return true
    }

    /// Whether every process in `processes` is still running half a second from now, time enough for a kill to land.
    private func staysRunning(_ processes: [Int32]) -> Bool {
        !waitUntil(within: 0.5) { processes.contains { MutatedProjectLock.startTime(of: $0) == nil } }
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
