import Foundation

/// Locks the mutated project a run uses, so that no other SwiftMutator run removes it, copies a project into it, or
/// replaces or removes its worker clones meanwhile.
protocol MutatedProjectLocking {
    /// The lock on `mutatedProject`, which needn't exist yet, held until it is released or SwiftMutator exits.
    /// Refused while another SwiftMutator process holds it.
    func lock(_ mutatedProject: URL) throws -> MutatedProjectLock
}

enum MutatedProjectLockError: Error, Equatable, CustomStringConvertible {
    /// Another SwiftMutator process holds the lock on `mutatedProject`: `process`, if it had written its ID yet.
    case inUse(mutatedProject: String, process: Int32?)
    case cannotLock(path: String, errno: Int32)

    var description: String {
        switch self {
        case let .inUse(mutatedProject, process):
            let holder = process.map { " (process \($0))" } ?? ""
            return "SwiftMutator won't start: another SwiftMutator run\(holder) is using \(mutatedProject), and two "
                + "runs of a project can't share its copy. Wait for that run to end, or stop it, then run again. "
                + "Nothing was copied or removed."
        case let .cannotLock(path, code):
            return "can't lock \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// An exclusive flock on the file beside a mutated project, `<project>_mutated.lock`. Every run of a project copies it
/// to the same folder and clones that folder for its workers, so a run holds the lock from before it removes the last
/// run's copy and clones until it exits, after it has removed its own clones. The kernel releases the lock when the
/// process exits, SIGKILL included, so it never goes stale. So the file is never removed, which would also let a run
/// lock a new file while another still held the old one. The descriptor is closed on exec, so no test process
/// SwiftMutator starts keeps it, or its lock, open.
final class MutatedProjectLock: Equatable {
    struct Locker: MutatedProjectLocking {
        func lock(_ mutatedProject: URL) throws -> MutatedProjectLock {
            let path = MutatedProjectLock.path(for: mutatedProject)
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw MutatedProjectLockError.cannotLock(path: path, errno: errno) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                let holder = code == EWOULDBLOCK ? MutatedProjectLock.process(writtenIn: descriptor) : nil
                close(descriptor)
                throw code == EWOULDBLOCK
                    ? MutatedProjectLockError.inUse(mutatedProject: mutatedProject.path, process: holder)
                    : MutatedProjectLockError.cannotLock(path: path, errno: code)
            }
            // Only for a refused run's message to name, so a failed write refuses nothing.
            let processID = Array("\(getpid())\n".utf8)
            _ = ftruncate(descriptor, 0)
            _ = pwrite(descriptor, processID, processID.count, 0)
            return MutatedProjectLock(descriptor: descriptor, path: path)
        }
    }

    /// The lock file.
    let path: String
    private var descriptor: Int32

    /// Takes over `descriptor`, open on `path` and already locked.
    init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        release()
    }

    /// Closes the file, which releases the lock.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    /// The same lock, as a run takes only one.
    static func == (lhs: MutatedProjectLock, rhs: MutatedProjectLock) -> Bool {
        lhs === rhs
    }

    /// The lock file of `mutatedProject`: beside it, named after it.
    static func path(for mutatedProject: URL) -> String {
        mutatedProject.path + ".lock"
    }

    /// The ID of the process that holds the lock, as it wrote it in the file. The file is empty, or names an earlier
    /// holder, in the moment between a run locking it and writing its own.
    private static func process(writtenIn descriptor: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let written = String(decoding: buffer.prefix(count), as: UTF8.self)
        return Int32(written.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
