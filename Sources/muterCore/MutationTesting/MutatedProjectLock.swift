import Foundation

/// Locks the mutated project a run uses, so that no other SwiftMutator run removes it, copies a project into it, or
/// replaces or removes its worker clones meanwhile.
protocol MutatedProjectLocking: Sendable {
    /// The lock on `mutatedProject`, which needn't exist yet, held until it is released or goes.
    /// Refused while another SwiftMutator process holds it.
    func lock(_ mutatedProject: URL) throws -> MutatedProjectLock

    /// Records that `process`, a test process, has started, in the lock this SwiftMutator process holds, if it holds one.
    func testProcessStarted(_ process: Int32)

    /// Records that the test process `process` has ended, in the lock this SwiftMutator process holds, if it holds one.
    func testProcessEnded(_ process: Int32)
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
///
/// Below its record, the holder lists the test processes it is running, the same way, and tells a watcher of its own
/// about them (`TestProcessWatcher`). Each leads a process group of its own, so if the holder dies first, killed with
/// SIGKILL or crashed, nothing else ends them. The watcher then kills them at once. If the watcher has died too, the run
/// that next takes the lock kills them, before it removes or uses the folders they run in: that run holds the lock, so
/// the run that listed them has ended.
final class MutatedProjectLock: Equatable, @unchecked Sendable { // every `var` is behind `access`
    final class Locker: MutatedProjectLocking, @unchecked Sendable { // `held` is behind `access`
        private let access = NSLock()
        /// The lock this gave out last, while it is held.
        private weak var held: MutatedProjectLock?
        private let startWatcher: @Sendable () -> TestProcessWatcher?

        /// `startWatcher` starts the watcher of a lock's test processes, as the first starts.
        init(startWatcher: @escaping @Sendable () -> TestProcessWatcher? = { TestProcessWatcher.start() }) {
            self.startWatcher = startWatcher
        }

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
            // Before this run's record replaces the list, and before anything in the folders they run in is removed or
            // used.
            MutatedProjectLock.terminateTestProcesses(listedIn: descriptor)
            let lock = MutatedProjectLock(
                descriptor: descriptor,
                path: path,
                holder: MutatedProjectLock.record(of: getpid()) ?? "",
                startWatcher: startWatcher
            )
            access.withLock { held = lock }
            return lock
        }

        func testProcessStarted(_ process: Int32) {
            access.withLock { held }?.testProcessStarted(process)
        }

        func testProcessEnded(_ process: Int32) {
            access.withLock { held }?.testProcessEnded(process)
        }
    }

    /// The lock file.
    let path: String
    private let access = NSLock()
    private var descriptor: Int32
    /// The holder's record, the file's first line, or nothing if the holder's start can't be read.
    private let holder: String
    /// The test processes the holder is running, by ID.
    private var testProcesses: [Int32: RecordedProcess] = [:]
    private let startWatcher: @Sendable () -> TestProcessWatcher?
    private var watcher: TestProcessWatcher?
    private var watcherStarted = false

    /// Takes over `descriptor`, open on `path` and already locked, and records `holder` in it. `startWatcher` starts the
    /// watcher of the holder's test processes, as the first starts.
    init(
        descriptor: Int32,
        path: String,
        holder: String = "",
        startWatcher: @escaping @Sendable () -> TestProcessWatcher? = { nil }
    ) {
        self.descriptor = descriptor
        self.path = path
        self.holder = holder
        self.startWatcher = startWatcher
        writeRecord()
    }

    deinit {
        release()
    }

    /// Lists `process`, a test process the holder has just started, in the file, and tells the watcher, which starts
    /// with the first. Nothing once the lock is released, or for a process that has already ended.
    func testProcessStarted(_ process: Int32) {
        guard let recorded = RecordedProcess(process) else { return }
        access.withLock {
            guard descriptor >= 0 else { return }
            testProcesses[process] = recorded
            writeRecord()
            if !watcherStarted {
                watcherStarted = true
                watcher = startWatcher()
            }
            watcher?.started(recorded)
        }
    }

    /// Takes `process`, a test process that has ended, off the list, and tells the watcher.
    func testProcessEnded(_ process: Int32) {
        access.withLock {
            guard descriptor >= 0, testProcesses.removeValue(forKey: process) != nil else { return }
            writeRecord()
            watcher?.ended(process)
        }
    }

    /// Clears the holder's record and list, then closes the file, which releases the lock, and ends the watcher.
    func release() {
        access.withLock {
            guard descriptor >= 0 else { return }
            // While the lock is still held, so it never clears the next holder's record.
            _ = ftruncate(descriptor, 0)
            close(descriptor)
            descriptor = -1
            // Any test process still listed would have no one left to kill it: the watcher kills it as it ends.
            watcher?.close()
            watcher = nil
        }
    }

    /// Writes the holder's record, then a line `test <pid> <start>` for each test process it is running, over what the
    /// file held. Cut to length after the write, so a run that is refused always finds the holder's record. Only for a
    /// refused run's message, and the next holder, so a record that can't be written, as to a file opened read-only,
    /// stops nothing. On `access`, but for the initializer's call.
    private func writeRecord() {
        guard descriptor >= 0 else { return }
        let list = testProcesses.values.sorted { $0.id < $1.id }.map { "test \($0.id) \($0.started)\n" }
        let bytes = Array((holder + list.joined()).utf8)
        _ = pwrite(descriptor, bytes, bytes.count, 0)
        _ = ftruncate(descriptor, off_t(bytes.count))
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
        let fields = contents(of: descriptor).prefix { $0 != "\n" }.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let process = Int32(fields[0]), let started = UInt64(fields[1]),
              startTime(of: process) == started
        else { return nil }
        return process
    }

    /// Kills each test process the lock file at `descriptor` lists, with every process it started, if it still runs:
    /// for a run that has just taken the lock, so the run that listed them has ended. A list written before the system
    /// last started is left alone: its processes are gone, and on Linux, which counts a process's start from the
    /// system's, a process started since could seem to be one of them.
    static func terminateTestProcesses(listedIn descriptor: Int32) {
        guard let written = modificationTime(of: descriptor), let systemStarted = systemStartTime(),
              written > systemStarted
        else { return }
        for line in contents(of: descriptor).split(separator: "\n") {
            testProcess(listedOn: line)?.terminateIfRunning()
        }
    }

    /// The test process `line` lists, as `test <pid> <start>`, if it lists one.
    private static func testProcess(listedOn line: Substring) -> RecordedProcess? {
        let fields = line.split(separator: " ")
        guard fields.count == 3, fields[0] == "test", let id = Int32(fields[1]), let started = UInt64(fields[2])
        else { return nil }
        return RecordedProcess(id: id, started: started)
    }

    /// What the file at `descriptor` holds, from its start, up to 1 MiB: a holder's record and list are far shorter.
    private static func contents(of descriptor: Int32) -> String {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count < 1 << 20 {
            let count = pread(descriptor, &buffer, buffer.count, off_t(bytes.count))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes += buffer[..<count]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// When the file at `descriptor` was last written, in seconds since 1970.
    private static func modificationTime(of descriptor: Int32) -> TimeInterval? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        #if os(macOS)
        let time = info.st_mtimespec
        #else
        let time = info.st_mtim
        #endif
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    /// When the system last started, in seconds since 1970, or nil if it can't tell.
    static func systemStartTime() -> TimeInterval? {
        #if os(macOS)
        var start = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &start, &size, nil, 0) == 0 else { return nil }
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        #else
        // proc(5): "btime", in seconds.
        guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = stat.split(separator: "\n").first(where: { $0.hasPrefix("btime ") })
        else { return nil }
        return TimeInterval(line.dropFirst("btime ".count))
        #endif
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
