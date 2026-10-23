@testable import muterCore
import XCTest

final class MutatedProjectLockTests: XCTestCase {
    private var directory = ""
    private let locker = MutatedProjectLock.Locker()

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

    /// Locks the file as a holder does before it records itself, until the test ends.
    func holdLockWithoutRecording() throws {
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        addTeardownBlock { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }
}
