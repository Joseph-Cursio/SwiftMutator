@testable import muterCore
import XCTest

/// These run real processes, and kill every one they start however a test ends.
final class ProcessTreeTests: XCTestCase {
    private var directory: URL!
    private var launched: [Foundation.Process] = []
    /// Descendants a test started that may still be running.
    private var unconfirmedGone: Set<Int32> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unconfirmedGone.forEach { kill($0, SIGKILL) }
        for process in launched where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // A test can end before it reads the ID of every process a shell started, as when launchTree gives
        // up waiting, and a shell killed alone leaves its children running. Foundation.Process starts each
        // launched process in a process group of its own, and the shells' background jobs stay in it, so
        // kill each group until no process is left in it: a process a shell was starting as its group was
        // killed can join the group after the signal. A group found empty is never signalled again.
        var groups = Set(launched.map(\.processIdentifier).filter { $0 > 1 }) // kill(-1) signals everything
        let groupsEmptied = waitUntil(within: 5) {
            groups = groups.filter { kill(-$0, SIGKILL) == 0 || errno != ESRCH }
            return groups.isEmpty
        }
        XCTAssertTrue(groupsEmptied, "processes are left in the process groups \(groups.sorted())")
        XCTAssertTrue(waitUntil(within: 5) { !self.launched.contains(where: \.isRunning) })
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func test_descendants_listsEveryDescendantOfARealProcess() throws {
        let tree = try launchTree()

        var descendants: [Int32] = []
        _ = waitUntil(within: 2) {
            descendants = ProcessTree.descendants(of: tree.root.processIdentifier)
            return descendants.count >= tree.descendants.count
        }

        XCTAssertEqual(descendants.sorted(), tree.descendants.sorted())
        let shell = try XCTUnwrap(descendants.firstIndex(of: tree.shell))
        let shellsSleeper = try XCTUnwrap(descendants.firstIndex(of: tree.shellsSleeper))
        XCTAssertLessThan(shell, shellsSleeper, "a parent comes before its children")
    }

    // How a stop tells the processes whose stop didn't hold, to stop them again. Started by `spawn`, which Foundation
    // doesn't reap, the sleeper stays a zombie once killed, until the test reaps it.
    func test_isStoppedOrEnded_isFalseOnlyWhileAProcessRuns() throws {
        let pid = try spawn("/bin/sleep", "61.34")

        XCTAssertFalse(ProcessTree.isStoppedOrEnded(pid), "running")
        kill(pid, SIGSTOP)
        XCTAssertTrue(waitUntil(within: 2) { ProcessTree.isStoppedOrEnded(pid) }, "stopped")
        kill(pid, SIGCONT)
        XCTAssertTrue(waitUntil(within: 2) { !ProcessTree.isStoppedOrEnded(pid) }, "continued")
        kill(pid, SIGKILL)
        XCTAssertTrue(waitUntil(within: 2) { ProcessTree.isStoppedOrEnded(pid) }, "a zombie")
        XCTAssertEqual(kill(pid, 0), 0, "reaped already")
        waitpid(pid, nil, 0)
        XCTAssertTrue(ProcessTree.isStoppedOrEnded(pid), "gone")
    }

    func test_descendants_ofAProcessWithNoChildren_isEmpty() throws {
        let sleeper = Foundation.Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["61.33"]
        try sleeper.run()
        launched.append(sleeper)

        XCTAssertEqual(ProcessTree.descendants(of: sleeper.processIdentifier), [])
    }

    // The first test of the real kill path: every other test of a run's kill uses a test double.
    func test_terminateTree_killsARealProcessAndEveryDescendant() throws {
        let tree = try launchTree()

        tree.root.terminateTree()

        let everyProcess = [tree.root.processIdentifier] + tree.descendants
        _ = waitUntil(within: 2) { everyProcess.allSatisfy(self.isGone) }
        XCTAssertEqual(everyProcess.filter { !isGone($0) }, [], "still running")
    }

    // A worker moves on to its next mutant once the kill returns, so it must return only once they have ended.
    func test_terminateTree_returnsOnceEveryDescendantHasEnded() throws {
        let tree = try launchTree()
        let descendants = tree.descendants
        XCTAssertFalse(descendants.isEmpty)

        tree.root.terminateTree()

        XCTAssertEqual(descendants.filter { MutatedProjectLock.startTime(of: $0) != nil }, [], "still running")
        // A zombie has ended but is still there. Once gone, tearDown won't signal whatever process gets its ID.
        _ = waitUntil(within: 2) { descendants.allSatisfy(self.isGone) }
    }

    // A process the kill can't list, as its parent has ended: as one the shell was starting as the stop came, it stays
    // in the shell's process group. The group's kill finds it.
    func test_killProcessGroup_killsWhatTheTreesKillCouldntList() throws {
        let root = Foundation.Process()
        root.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Named only once the subshell has ended, as until then a listing still finds the sleep through it.
        root.arguments = [
            "-c",
            "(/bin/sleep 61.35 & echo $! > escaped.tmp); mv escaped.tmp escaped; exec /bin/sleep 61.36",
        ]
        root.currentDirectoryURL = directory
        try root.run()
        launched.append(root)
        var escaped: Int32?
        _ = waitUntil(within: 5) {
            escaped = pid(writtenTo: "escaped")
            return escaped != nil
        }
        let stray = try XCTUnwrap(escaped)
        unconfirmedGone.insert(stray)

        root.terminateTree()
        // On Linux, Foundation hears of the exit only once the stray has gone, and the kernel says so at once. On
        // macOS, Foundation has reaped the shell, so the kernel has nothing to say about it.
        XCTAssertTrue(waitUntil(within: 2) { root.hasExited() || !root.isRunning }, "the shell is still running")
        XCTAssertFalse(isGone(stray), "the tree's kill listed it, so this tests nothing")

        root.killProcessGroup()

        XCTAssertTrue(waitUntil(within: 2) { isGone(stray) }, "still running")
    }

    // A process with its ID that hasn't ended is what the system gave the ID to once the process had been reaped, as
    // when SwiftMutator was stopped meanwhile, so neither it nor its group is SwiftMutator's to kill.
    func test_killProcessGroup_leavesAProcessWithThatIDAlone() throws {
        let tree = try launchTree()

        tree.root.killProcessGroup()

        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(tree.root.isRunning, "it was killed")
        XCTAssertFalse(isGone(tree.sleeper), "its group was killed")
    }

    // kill(0, …) would signal this test's own process group, and kill(-1, …) every process it may signal.
    func test_killProcessGroup_ofAProcessThatNeverLaunched_signalsNothing() {
        let neverLaunched = Foundation.Process()

        neverLaunched.killProcessGroup()

        XCTAssertEqual(neverLaunched.processIdentifier, 0)
    }

    // What a stopping SwiftMutator does to its own descendants, with a tree this test started as the root:
    // the test runner's own descendants include other tests' processes.
    func test_terminateDescendants_killsEveryDescendant_butNotTheRoot() throws {
        let tree = try launchTree()

        ProcessTree.terminateDescendants(
            of: tree.root.processIdentifier,
            descendants: ProcessTree.descendants(of:)
        ) { pid, signal in
            kill(pid, signal)
        }

        _ = waitUntil(within: 2) { tree.descendants.allSatisfy(self.isGone) }
        XCTAssertEqual(tree.descendants.filter { !isGone($0) }, [], "still running")
        // The root was never signalled: its `wait` returned once its children were gone, and it exited.
        XCTAssertTrue(waitUntil(within: 2) { !tree.root.isRunning }, "the root is still running")
        guard !tree.root.isRunning else { return }
        XCTAssertEqual(tree.root.terminationReason, .exit)
        XCTAssertEqual(tree.root.terminationStatus, 0)
    }

    // A terminal's Ctrl-C, or the hangup a shell forwards, signals the foreground process group. Each process
    // SwiftMutator starts leads a group of its own, so the signal reaches SwiftMutator alone, which cancels
    // the runs under way before it kills their processes. Otherwise a run the signal ended could be recorded
    // first, as a killed mutant.
    func test_aProcessSwiftMutatorStarts_leadsAProcessGroupOfItsOwn() throws {
        let process = try XCTUnwrap(MuterProcessFactory.makeProcess() as? Foundation.Process)
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["61.41"]
        try process.run()
        launched.append(process)
        let pid = process.processIdentifier

        XCTAssertEqual(getpgid(pid), pid)
        XCTAssertNotEqual(getpgid(pid), getpgrp())
    }

    // MARK: - Helpers

    /// A real process tree: `sh` starts a `sleep` and a second `sh`, which starts a second `sleep`.
    private struct Tree {
        let root: Foundation.Process
        let sleeper: Int32
        let shell: Int32
        let shellsSleeper: Int32

        /// Every descendant of `root`, each parent before its children.
        var descendants: [Int32] { [sleeper, shell, shellsSleeper] }
    }

    /// Starts a `Tree`. Each shell writes down the ID of each process it starts, so a test knows every
    /// descendant without listing them. The sleeps' odd lengths make any process left behind easy to find.
    private func launchTree(file: StaticString = #filePath, line: UInt = #line) throws -> Tree {
        let root = Foundation.Process()
        root.executableURL = URL(fileURLWithPath: "/bin/sh")
        root.arguments = [
            "-c",
            """
            /bin/sleep 61.31 & echo $! > sleeper
            /bin/sh -c '/bin/sleep 61.32 & echo $! > shellsSleeper; wait' & echo $! > shell
            wait
            """,
        ]
        root.currentDirectoryURL = directory
        try root.run()
        launched.append(root)

        var pids: [String: Int32] = [:]
        let names = ["sleeper", "shell", "shellsSleeper"]
        _ = waitUntil(within: 2) {
            for name in names where pids[name] == nil {
                pids[name] = self.pid(writtenTo: name)
            }
            return pids.count == names.count
        }
        unconfirmedGone.formUnion(pids.values)
        return try Tree(
            root: root,
            sleeper: XCTUnwrap(pids["sleeper"], file: file, line: line),
            shell: XCTUnwrap(pids["shell"], file: file, line: line),
            shellsSleeper: XCTUnwrap(pids["shellsSleeper"], file: file, line: line)
        )
    }

    private func pid(writtenTo name: String) -> Int32? {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether no process has this ID. Once a process is gone, it is never killed again: the system may
    /// give its ID to another process.
    private func isGone(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == -1, errno == ESRCH else { return false }
        unconfirmedGone.remove(pid)
        return true
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
