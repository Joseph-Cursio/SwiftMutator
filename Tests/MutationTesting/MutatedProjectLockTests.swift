@testable import muterCore
import XCTest

final class MutatedProjectLockTests: XCTestCase {
    private var directory = ""
    /// No watcher: the executable running these tests isn't SwiftMutator.
    private let locker = MutatedProjectLock.Locker(startWatcher: { nil })

    /// Never made: a run takes the lock before it copies the project.
    private var mutatedProject: URL {
        URL(fileURLWithPath: "\(directory)/x_mutated")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    // Beside the copy, which a run removes and makes again while it holds the lock.
    func test_theLockIsAFileBesideTheMutatedProject_whichNeedNotExistYet() throws {
        let lock = try locker.lock(mutatedProject)

        XCTAssertEqual(lock.path, "\(directory)/x_mutated.lock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mutatedProject.path))
    }

    func test_aSecondRunIsRefusedWhileTheFirstHoldsTheLock_namingTheFolderAndTheProcess() throws {
        let first = try locker.lock(mutatedProject)

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: getpid())
            )
        }
        withExtendedLifetime(first) {}
    }

    // Each run names the folder its own way, such as through a symbolic link, but there is only one lock file.
    func test_aRunReachingTheFolderThroughAnotherPath_isRefusedToo() throws {
        let (real, link) = try makeDirectoryWithSymbolicLink()
        let first = try locker.lock(URL(fileURLWithPath: "\(real)/x_mutated"))

        XCTAssertThrowsError(try locker.lock(URL(fileURLWithPath: "\(link)/x_mutated"))) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: "\(link)/x_mutated", process: getpid())
            )
        }
        withExtendedLifetime(first) {}
    }

    func test_aRunOfAnotherProjectBesideIt_isNotRefused() throws {
        let first = try locker.lock(mutatedProject)

        XCTAssertNoThrow(try locker.lock(URL(fileURLWithPath: "\(directory)/y_mutated")))
        withExtendedLifetime(first) {}
    }

    func test_theLockIsReleasedWhenReleased() throws {
        try locker.lock(mutatedProject).release()

        XCTAssertNoThrow(try locker.lock(mutatedProject))
    }

    // As when the state that holds it goes, once SwiftMutator's work has ended.
    func test_theLockIsReleasedWhenItGoes() throws {
        var first: MutatedProjectLock? = try locker.lock(mutatedProject)
        XCTAssertNotNil(first)

        first = nil

        XCTAssertNoThrow(try locker.lock(mutatedProject))
    }

    // A run killed at once leaves its record, which the next holder replaces. Longer than any record, so what is left
    // of it past the new one would spoil that.
    func test_aRunThatTakesTheLock_recordsItsProcessIDAndStart_overAnEarlierRecord() throws {
        try writeRecord("99999999 99999999999999999999999999999999\n")

        let lock = try locker.lock(mutatedProject)

        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: getpid()))
        XCTAssertEqual(try String(contentsOfFile: lock.path, encoding: .utf8), "\(getpid()) \(start)\n")
    }

    // So a run that has finished is never named, even while its process is still exiting.
    func test_releasingTheLock_clearsTheRecord() throws {
        let lock = try locker.lock(mutatedProject)

        lock.release()

        XCTAssertEqual(try String(contentsOfFile: lock.path, encoding: .utf8), "")
    }

    // In the moment between a run locking the file and recording itself, the file names no process, or an earlier one.
    func test_aHolderThatHasNotRecordedItself_isNotNamed() throws {
        try holdLockWithoutRecording()

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: nil)
            )
        }
    }

    // A run killed at once leaves its record. Naming its process, gone, would send the user looking for it.
    func test_aRecordOfAProcessThatHasEnded_namesNoOne() throws {
        let child = try spawn("/bin/sleep", "30")
        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: child))
        kill(child, SIGKILL)
        waitpid(child, nil, 0)
        try writeRecord("\(child) \(start)\n")
        try holdLockWithoutRecording()

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: nil)
            )
        }
    }

    // A killed run's ID can go to another process, which the message would then tell the user to stop.
    func test_aRecordWhoseProcessIDAnotherProcessNowHas_namesNoOne() throws {
        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: getpid()))
        try writeRecord("\(getpid()) \(start - 1)\n")
        try holdLockWithoutRecording()

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: nil)
            )
        }
    }

    // A holder killed at once, which its parent hasn't reaped yet, still has its ID and start, but it has ended.
    func test_aRecordOfAProcessThatHasEndedButIsNotReaped_namesNoOne() throws {
        let child = try spawn("/bin/sleep", "30")
        defer { waitpid(child, nil, 0) }
        let start = try XCTUnwrap(MutatedProjectLock.startTime(of: child))
        kill(child, SIGKILL)
        // Waits for it to end, and leaves it unreaped.
        var info = siginfo_t()
        XCTAssertEqual(waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT), 0)
        XCTAssertNil(MutatedProjectLock.startTime(of: child))
        try writeRecord("\(child) \(start)\n")
        try holdLockWithoutRecording()

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: nil)
            )
        }
    }

    func test_aRecordThatIsNotOne_namesNoOne() throws {
        try writeRecord("\(getpid())\n")
        try holdLockWithoutRecording()

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: nil)
            )
        }
    }

    func test_startTime_tellsAProcessFromALaterOne_andNoProcessIsNone() throws {
        let own = try XCTUnwrap(MutatedProjectLock.startTime(of: getpid()))
        XCTAssertEqual(MutatedProjectLock.startTime(of: getpid()), own)
        let child = try spawn("/bin/sleep", "30")
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }

        XCTAssertGreaterThan(try XCTUnwrap(MutatedProjectLock.startTime(of: child)), own)
        XCTAssertNil(MutatedProjectLock.startTime(of: 0))
        XCTAssertNil(MutatedProjectLock.startTime(of: -1))
    }

    // The holder can be another user's run, in a checkout shared through a group. Process 1, launchd or init, is
    // root's.
    func test_startTime_ofAnotherUsersProcess_canBeRead() {
        XCTAssertNotNil(MutatedProjectLock.startTime(of: 1))
    }

    // On a Linux NFS mount, a descriptor opened read-only can't take an exclusive lock, and gets EBADF.
    func test_aFailedFlock_ofAFileOpenedReadOnly_isReportedWithWhyItCouldNotBeWritten() {
        XCTAssertEqual(MutatedProjectLock.reportedErrno(ofFailedFlock: EBADF, openedReadOnlyBecause: EACCES), EACCES)
        XCTAssertEqual(MutatedProjectLock.reportedErrno(ofFailedFlock: ENOLCK, openedReadOnlyBecause: EACCES), ENOLCK)
        XCTAssertEqual(MutatedProjectLock.reportedErrno(ofFailedFlock: EBADF, openedReadOnlyBecause: nil), EBADF)
        XCTAssertEqual(MutatedProjectLock.reportedErrno(ofFailedFlock: ENOLCK, openedReadOnlyBecause: nil), ENOLCK)
    }

    // In a checkout shared through a group, whoever can remove the copy must be able to lock it.
    func test_aNewLockFile_getsThePermissionsTheUmaskLeaves() throws {
        let previous = umask(0o002)
        defer { umask(previous) }

        let lock = try locker.lock(mutatedProject)

        let permissions = try FileManager.default.attributesOfItem(atPath: lock.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o664)
    }

    // flock needs no more than a read-only descriptor, so a file another user made is no reason to refuse.
    func test_aLockFileThisUserCanOnlyRead_isLockedReadOnly_andStillKeepsOthersOut() throws {
        try writeRecord("")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: lockPath)

        let first = try locker.lock(mutatedProject)

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            // Root opens it read-write, so records itself.
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: geteuid() == 0 ? getpid() : nil)
            )
        }
        if geteuid() != 0 {
            XCTAssertEqual(try String(contentsOfFile: lockPath, encoding: .utf8), "", "a read-only file isn't written")
        }
        withExtendedLifetime(first) {}
    }

    // Making the file fails, and there is no file to open read-only: the error is why it couldn't be made.
    func test_aLockFileThatCannotBeMade_saysWhy() throws {
        try XCTSkipIf(geteuid() == 0, "root can write to any folder")
        let folder = "\(directory)/read-only"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }

        XCTAssertThrowsError(try locker.lock(URL(fileURLWithPath: "\(folder)/x_mutated"))) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .cannotLock(path: "\(folder)/x_mutated.lock", errno: EACCES)
            )
        }
    }

    // A test process outlives a run killed with SIGKILL, and would otherwise keep every later run out.
    func test_aProcessStartedWhileTheLockIsHeld_doesNotInheritIt_soCannotKeepItLocked() throws {
        let lock = try locker.lock(mutatedProject)
        // posix_spawn with no attributes passes on every descriptor not marked close-on-exec.
        let child = try spawn("/bin/sleep", "30")
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }

        lock.release()

        XCTAssertNoThrow(try locker.lock(mutatedProject))
    }

    // MARK: - Test processes

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
        XCTAssertEqual(try String(contentsOfFile: lock.path, encoding: .utf8), "\(getpid()) \(start)\n")
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

    func test_systemStartTime_isInThePast() throws {
        let started = try XCTUnwrap(MutatedProjectLock.systemStartTime())

        XCTAssertLessThan(started, Date().timeIntervalSince1970)
        XCTAssertGreaterThan(started, Date(timeIntervalSinceReferenceDate: 0).timeIntervalSince1970)
    }

    // Not with the lock: a run that is refused, or fails before it tests, starts none. One watcher serves every test
    // process, and ends as the lock is released, killing any still listed: no one would be left to kill it.
    func test_theWatcherStartsWithTheFirstTestProcess_andEndsWithTheLock() throws {
        let watchers = WatchersInThisProcess()
        let locker = MutatedProjectLock.Locker(startWatcher: { watchers.start() })
        let lock = try locker.lock(mutatedProject)
        XCTAssertEqual(watchers.count, 0)
        let ended = try spawnSleeper()
        let running = try spawnSleeper()

        locker.testProcessStarted(ended.id)
        locker.testProcessStarted(running.id)
        locker.testProcessEnded(ended.id)
        XCTAssertEqual(watchers.count, 1)
        lock.release()

        XCTAssertEqual(watchers.ended.wait(timeout: .now() + 5), .success, "the watcher didn't end")
        XCTAssertTrue(waitUntilGone([running.id]), "still running")
        XCTAssertTrue(staysRunning([ended.id]), "a process that had ended was killed")
    }

    func test_aFolderThatIsMissing_saysWhy() {
        let mutatedProject = URL(fileURLWithPath: "\(directory)/missing/x_mutated")

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .cannotLock(path: "\(directory)/missing/x_mutated.lock", errno: ENOENT)
            )
        }
    }

    func test_errorsSayWhatHappened() {
        XCTAssertEqual(
            MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: 81234).description,
            "SwiftMutator won't start: another SwiftMutator run (process 81234) is using /code/x_mutated, and two "
                + "runs of a project can't share its copy. Wait for that run to end, or stop it, then run again. "
                + "Nothing was copied or removed."
        )
        XCTAssertEqual(
            MutatedProjectLockError.inUse(mutatedProject: "/code/x_mutated", process: nil).description,
            "SwiftMutator won't start: another SwiftMutator run is using /code/x_mutated, and two runs of a project "
                + "can't share its copy. Wait for that run to end, or stop it, then run again. "
                + "Nothing was copied or removed."
        )
        XCTAssertEqual(
            MutatedProjectLockError.cannotLock(path: "/code/x_mutated.lock", errno: EACCES).description,
            "can't lock /code/x_mutated.lock: Permission denied"
        )
    }
}

private extension MutatedProjectLockTests {
    var lockPath: String {
        MutatedProjectLock.path(for: mutatedProject)
    }

    func writeRecord(_ record: String) throws {
        try Data(record.utf8).write(to: URL(fileURLWithPath: lockPath))
    }

    /// A `sleep` this test started, killed and reaped when the test ends.
    func spawnSleeper() throws -> RecordedProcess {
        let child = try spawn("/bin/sleep", "61.61")
        addTeardownBlock {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }
        return try XCTUnwrap(RecordedProcess(child))
    }

    /// A test command's process tree: `sh`, the root, and the `sleep` it started, each killed when the test ends if it
    /// still runs, and the root reaped.
    func spawnTree() throws -> (root: RecordedProcess, sleeper: Int32) {
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
    func waitUntilGone(_ processes: [Int32]) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while processes.contains(where: { MutatedProjectLock.startTime(of: $0) != nil }) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Whether every process in `processes` is still running half a second from now, time enough for a kill to land.
    func staysRunning(_ processes: [Int32]) -> Bool {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            guard processes.allSatisfy({ MutatedProjectLock.startTime(of: $0) != nil }) else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    /// Locks the file as a holder does before it records itself, until the test ends.
    func holdLockWithoutRecording() throws {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        addTeardownBlock { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }
}

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
