import Foundation

/// Locks the mutated project a run uses, so that no other SwiftMutator run removes it, copies a project into it, or
/// replaces or removes its worker clones meanwhile.
protocol MutatedProjectLocking {
    /// The lock on `mutatedProject`, which needn't exist yet, held until it is released or goes.
    /// Refused while another SwiftMutator process holds it.
    func lock(_ mutatedProject: URL) throws -> MutatedProjectLock
}

enum MutatedProjectLockError: Error, Equatable, CustomStringConvertible {
    /// Another SwiftMutator process holds the lock on `mutatedProject`: `process`, if the lock file shows which.
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
/// to the same folder and clones that folder for its workers, so a run takes the lock before it removes the last run's
/// copy and clones, and keeps it until its work has ended, after it has removed its own clones. The kernel releases the
/// lock when the process exits, SIGKILL included, so it never goes stale. So the file is never removed, which would
/// also let a run lock a new file while another still held the old one. The descriptor is closed on exec, so no test
/// process SwiftMutator starts keeps it, or its lock, open.
///
/// The holder records its process ID in the file, and when that process started, and clears them as it releases the
/// lock, so a run that is refused can name it. A record is believed only while the process with that ID started then:
/// a holder killed at once leaves its record, and its ID can go to another process.
final class MutatedProjectLock: Equatable {
    struct Locker: MutatedProjectLocking {
        func lock(_ mutatedProject: URL) throws -> MutatedProjectLock {
            let path = MutatedProjectLock.path(for: mutatedProject)
            let (descriptor, readOnlyBecause) = try MutatedProjectLock.openFile(at: path)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                let holder = code == EWOULDBLOCK ? MutatedProjectLock.holder(recordedIn: descriptor) : nil
                close(descriptor)
                throw code == EWOULDBLOCK
                    ? MutatedProjectLockError.inUse(mutatedProject: mutatedProject.path, process: holder)
                    : MutatedProjectLockError.cannotLock(
                        path: path,
                        errno: MutatedProjectLock.reportedErrno(
                            ofFailedFlock: code,
                            openedReadOnlyBecause: readOnlyBecause
                        )
                    )
            }
            // Only for a refused run's message, so a record that can't be written, as to a file opened read-only,
            // refuses nothing: the holder goes unnamed.
            if let record = MutatedProjectLock.record(of: getpid()) {
                let bytes = Array(record.utf8)
                _ = ftruncate(descriptor, 0)
                _ = pwrite(descriptor, bytes, bytes.count, 0)
            }
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

    /// Clears the holder's record, then closes the file, which releases the lock.
    func release() {
        guard descriptor >= 0 else { return }
        // While the lock is still held, so it never clears the next holder's record.
        _ = ftruncate(descriptor, 0)
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

    /// The lock file at `path`, made if it's missing. A new file gets whatever permissions the umask leaves, as the
    /// copy beside it does, so anyone who can remove the copy can lock it. A file this user can only read is opened
    /// read-only, which is all flock needs on a local disk; `readOnlyBecause` is why it couldn't be opened to write.
    private static func openFile(at path: String) throws -> (descriptor: Int32, readOnlyBecause: Int32?) {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o666)
        guard descriptor < 0 else { return (descriptor, nil) }
        let code = errno
        if code == EACCES {
            let readOnly = open(path, O_RDONLY | O_CLOEXEC)
            if readOnly >= 0 { return (readOnly, code) }
        }
        throw MutatedProjectLockError.cannotLock(path: path, errno: code)
    }

    /// The error a flock that failed with `code` is reported with. Where flock is emulated with fcntl locks, as on a
    /// Linux NFS mount, an exclusive lock needs a descriptor open to write, and one opened read-only gets EBADF, which
    /// would read as SwiftMutator's own bug: what stopped the run is why the file couldn't be opened to write.
    static func reportedErrno(ofFailedFlock code: Int32, openedReadOnlyBecause reason: Int32?) -> Int32 {
        code == EBADF ? reason ?? code : code
    }

    /// What the lock file records of `process`: its ID, and when it started, which tells it apart from a later process
    /// given the same ID. Nil if its start can't be read.
    private static func record(of process: Int32) -> String? {
        startTime(of: process).map { "\(process) \($0)\n" }
    }

    /// The holder that `descriptor`'s file records, if that process still runs. None is named in the moment between a
    /// run locking the file and recording itself, or if the holder couldn't record itself.
    private static func holder(recordedIn descriptor: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let fields = String(decoding: buffer.prefix(count), as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let process = Int32(fields[0]), let started = UInt64(fields[1]),
              startTime(of: process) == started
        else { return nil }
        return process
    }

    /// When `process` started, as the kernel records it, or nil if it can't tell, as when no such process runs, or it
    /// has ended and waits to be reaped. Any user's process can be asked about: another user's run can hold the lock.
    static func startTime(of process: Int32) -> UInt64? {
        guard process > 0 else { return nil }
        #if os(macOS)
        // Not proc_pidinfo, which answers only about this user's processes.
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, process]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // No such process leaves `size` 0.
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0,
              Int32(info.kp_proc.p_stat) != SZOMB
        else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
        #else
        // The command, in parentheses, may hold spaces and parentheses itself, so the fields are counted from its
        // last ")": the first after it is the state, field 3 in proc(5), and the 20th the start time, field 22.
        guard let stat = try? String(contentsOfFile: "/proc/\(process)/stat", encoding: .utf8),
              let commandEnd = stat.lastIndex(of: ")")
        else { return nil }
        let fields = stat[stat.index(after: commandEnd)...].split(separator: " ")
        // A zombie, or a process being reaped ("X", or "x" before Linux 3.14), has ended.
        guard fields.count > 19, !["Z", "X", "x"].contains(fields[0]) else { return nil }
        return UInt64(fields[19])
        #endif
    }
}
