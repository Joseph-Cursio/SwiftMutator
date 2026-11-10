@testable import muterCore
import XCTest

/// Starts watchers that run on threads of this process, as `swift-mutator watch-test-processes` runs.
private final class WatchersInThisProcess: @unchecked Sendable { // `started` is behind `lock`
    private let lock = NSLock()
    private var started = 0
    /// Signalled as each watcher ends.
    let ended = DispatchSemaphore(value: 0)

    /// How many have started.
    var count: Int { lock.withLock { started } }

    func start() -> TestProcessWatcher? {
        guard let ends = TestProcessWatcher.makePipe() else { return nil }
        lock.withLock { started += 1 }
        Thread.detachNewThread { [ended] in
            TestProcessWatcher.watch(readingFrom: ends.read)
            close(ends.read)
            ended.signal()
        }
        return TestProcessWatcher(writingTo: ends.write)
    }
}

/// The test processes the holder of a mutated project's lock lists below its record, and what the run that next takes
/// the lock, or the holder's watcher, does with those left running.
final class MutatedProjectLockTestProcessTests: XCTestCase {
    private let directory = XCTestCase.unusedTemporaryPath()
    /// No watcher: the executable running these tests isn't SwiftMutator.
    private let locker = MutatedProjectLock.Locker { nil }

    /// Never made: a run takes the lock before it copies the project.
    private var mutatedProject: URL {
        URL(fileURLWithPath: "\(directory)/x_mutated.noindex")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    // So that if the holder dies first, killed or crashed, the run that next takes the lock can kill them.
    func test_theHolderListsEachTestProcessItRuns_belowItsRecord_untilItEnds() throws {
        let lock = try locker.lock(mutatedProject)
        let holder = try String(contentsOfFile: lockPath, encoding: .utf8)
        let first = try spawnSleeper()
        let second = try spawnSleeper()

        locker.testProcessStarted(second.id)
        locker.testProcessStarted(first.id)

        let both = [first, second].sorted { $0.id < $1.id }.map { "test \($0.id) \($0.started)\n" }.joined()
        XCTAssertEqual(try String(contentsOfFile: lockPath, encoding: .utf8), holder + both)
        locker.testProcessEnded(first.id)
        XCTAssertEqual(
            try String(contentsOfFile: lockPath, encoding: .utf8),
            holder + "test \(second.id) \(second.started)\n"
        )
        locker.testProcessEnded(second.id)
        XCTAssertEqual(try String(contentsOfFile: lockPath, encoding: .utf8), holder)
        withExtendedLifetime(lock) {}
    }

    func test_aRefusedRun_stillNamesAHolderThatListsTestProcesses() throws {
        let first = try locker.lock(mutatedProject)
        locker.testProcessStarted(try spawnSleeper().id)

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: getpid())
            )
        }
        withExtendedLifetime(first) {}
    }

    func test_noTestProcessIsListed_onceTheLockIsReleasedOrHasGone() throws {
        let lock = try locker.lock(mutatedProject)
        locker.testProcessStarted(try spawnSleeper().id)
        lock.release()
        locker.testProcessStarted(try spawnSleeper().id)
        lock.testProcessStarted(try spawnSleeper().id)
        XCTAssertEqual(try String(contentsOfFile: lockPath, encoding: .utf8), "")

        var other: MutatedProjectLock? = try locker.lock(URL(fileURLWithPath: "\(directory)/y_mutated"))
        XCTAssertNotNil(other)
        other = nil
        locker.testProcessStarted(try spawnSleeper().id)
        XCTAssertEqual(try String(contentsOfFile: "\(directory)/y_mutated.lock", encoding: .utf8), "")
    }

    // The run that listed them has ended, killed or crashed, as this one holds the lock. They are killed before this
    // run removes or uses the folders they run in.
    func test_aRunThatTakesTheLock_killsTheTestProcessesTheLastHolderLeftRunning_withEveryProcessTheyStarted() throws {
        let tree = try spawnTree()
        let other = try spawnTree()
        try writeRecord(
            "99999999 1\ntest \(tree.root.id) \(tree.root.started)\ntest \(other.root.id) \(other.root.started)\n"
        )

        let lock = try locker.lock(mutatedProject)

        let everyProcess = [tree.root.id, tree.sleeper, other.root.id, other.sleeper]
        XCTAssertTrue(waitUntilGone(everyProcess), "still running")
        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: getpid()))
        XCTAssertEqual(
            try String(contentsOfFile: lock.path, encoding: .utf8),
            "\(getpid()) \(start)\ncopy \(mutatedProject.path)\n"
        )
    }

    // Its ID may have gone to another process.
    func test_aListedProcessThatStartedAtAnotherTime_isLeftAlone() throws {
        let sleeper = try spawnSleeper()
        try writeRecord("99999999 1\ntest \(sleeper.id) \(sleeper.started - 1)\n")

        _ = try locker.lock(mutatedProject)

        XCTAssertTrue(staysRunning([sleeper.id]), "another process was killed")
    }

    // Its processes are gone, and on Linux a process started since could seem to be one of them.
    func test_aListWrittenBeforeTheSystemLastStarted_isLeftAlone() throws {
        let sleeper = try spawnSleeper()
        try writeRecord("99999999 1\ntest \(sleeper.id) \(sleeper.started)\n")
        let systemStarted = try XCTUnwrap(MutatedProjectLock.systemStartTime())
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: systemStarted - 60)],
            ofItemAtPath: lockPath
        )

        _ = try locker.lock(mutatedProject)

        XCTAssertTrue(staysRunning([sleeper.id]), "a process was killed")
    }

    // Not with the lock: a run that is refused, or fails before it tests, starts none. One watcher serves every test
    // process, and ends as the lock is released, killing any still listed: no one would be left to kill it.
    func test_theWatcherStartsWithTheFirstTestProcess_andEndsWithTheLock() throws {
        let watchers = WatchersInThisProcess()
        let watchedLocker = MutatedProjectLock.Locker { watchers.start() }
        let lock = try watchedLocker.lock(mutatedProject)
        XCTAssertEqual(watchers.count, 0)
        let ended = try spawnSleeper()
        let running = try spawnSleeper()

        watchedLocker.testProcessStarted(ended.id)
        watchedLocker.testProcessStarted(running.id)
        watchedLocker.testProcessEnded(ended.id)
        XCTAssertEqual(watchers.count, 1)
        lock.release()

        XCTAssertEqual(watchers.ended.wait(timeout: .now() + 5), .success, "the watcher didn't end")
        XCTAssertTrue(waitUntilGone([running.id]), "still running")
        XCTAssertTrue(staysRunning([ended.id]), "a process that had ended was killed")
    }

    private var lockPath: String {
        MutatedProjectLock.path(for: mutatedProject)
    }

    private func writeRecord(_ record: String) throws {
        try Data(record.utf8).write(to: URL(fileURLWithPath: lockPath))
    }

    /// A `sleep` this test started, killed and reaped when the test ends.
    private func spawnSleeper() throws -> RecordedProcess {
        let child = try spawn("/bin/sleep", "61.61")
        addTeardownBlock {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }
        return try XCTUnwrap(RecordedProcess(child))
    }

    /// A test command's process tree: `sh`, the root, and the `sleep` it started, each killed when the test ends if it
    /// still runs, and the root reaped.
    private func spawnTree() throws -> (root: RecordedProcess, sleeper: Int32) {
        let file = "\(directory)/sleeper-\(UUID().uuidString)"
        let root = try spawn("/bin/sh", "-c", "/bin/sleep 61.62 & echo $! > \(file); wait")
        addTeardownBlock {
            kill(root, SIGKILL)
            waitpid(root, nil, 0)
        }
        var sleeper: Int32?
        let deadline = Date().addingTimeInterval(2)
        while sleeper == nil, Date() < deadline {
            sleeper = (try? String(contentsOfFile: file, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pid = try XCTUnwrap(sleeper, "the shell didn't start its sleep")
        addTeardownBlock {
            if MutatedProjectLock.startTime(of: pid) != nil { kill(pid, SIGKILL) }
        }
        return (try XCTUnwrap(RecordedProcess(root)), pid)
    }

    /// Waits up to 2 seconds for every process in `processes` to end, and returns whether they did. One that has ended
    /// but waits to be reaped counts.
    private func waitUntilGone(_ processes: [Int32]) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while processes.contains(where: { MutatedProjectLock.startTime(of: $0) != nil }) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Whether every process in `processes` is still running half a second from now, time enough for a kill to land.
    private func staysRunning(_ processes: [Int32]) -> Bool {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            guard processes.allSatisfy({ MutatedProjectLock.startTime(of: $0) != nil }) else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
