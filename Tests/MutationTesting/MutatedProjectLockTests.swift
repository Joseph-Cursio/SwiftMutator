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

    // An earlier run's ID stays in the file once it exits, and its lock goes with it.
    func test_aRunThatTakesTheLock_writesItsProcessID_overAnEarlierRuns() throws {
        try Data("99999999\n".utf8).write(to: URL(fileURLWithPath: MutatedProjectLock.path(for: mutatedProject)))

        let lock = try locker.lock(mutatedProject)

        XCTAssertEqual(try String(contentsOfFile: lock.path, encoding: .utf8), "\(getpid())\n")
    }

    // In the moment between a run locking the file and writing its ID, the file names no process, or an earlier one.
    func test_aHolderThatHasNotWrittenItsID_isNotNamed() throws {
        let descriptor = open(MutatedProjectLock.path(for: mutatedProject), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(try locker.lock(mutatedProject)) { error in
            XCTAssertEqual(
                error as? MutatedProjectLockError,
                .inUse(mutatedProject: mutatedProject.path, process: nil)
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
