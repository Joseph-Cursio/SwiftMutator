import Foundation

/// A process, told apart from a later process given the same ID by when it started.
struct RecordedProcess: Hashable {
    let id: Int32
    /// When it started, as `MutatedProjectLock.startTime(of:)` reads it.
    let started: UInt64

    init(id: Int32, started: UInt64) {
        self.id = id
        self.started = started
    }

    /// The record of the process `id`, or nil if no such process runs.
    init?(_ id: Int32) {
        guard let started = MutatedProjectLock.startTime(of: id) else { return nil }
        self.init(id: id, started: started)
    }

    /// Stops and kills the process and every process it started, as `MuterProcess.terminateTree()` does, if it still
    /// runs. A process that has ended is left alone, and so is whatever process its ID went to.
    func terminateIfRunning() {
        guard MutatedProjectLock.startTime(of: id) == started else { return }
        ProcessTree.terminate(root: id, descendants: ProcessTree.descendants(of:)) { pid, signal in
            kill(pid, signal)
        }
    }
}

/// Kills the test processes SwiftMutator is running if SwiftMutator dies before them, killed with SIGKILL or crashed,
/// which it can't handle itself. Each test process leads a process group of its own, so nothing else ends them.
///
/// The watcher is SwiftMutator's own executable, run as `swift-mutator watch-test-processes`. It reads a pipe that only
/// SwiftMutator writes to: `+<pid> <start>` as a test process starts, and `-<pid>` once it has ended. When the pipe
/// closes, as it does when SwiftMutator exits however it ends, the watcher kills each test process still listed, with
/// every process that one started, and exits. A stop kills the watcher with every other process SwiftMutator started:
/// SwiftMutator then kills its test processes itself.
final class TestProcessWatcher: @unchecked Sendable { // `descriptor` is behind `lock`
    private let lock = NSLock()
    /// The pipe's end SwiftMutator writes to, or -1 once it's closed.
    private var descriptor: Int32
    /// The watcher's own process, if this started one.
    let process: Foundation.Process?

    /// Writes to the watcher reading the other end of the pipe whose end `descriptor` is, which this then owns.
    init(writingTo descriptor: Int32, process: Foundation.Process? = nil) {
        self.descriptor = descriptor
        self.process = process
    }

    deinit {
        close()
    }

    /// Starts the watcher, `executable` run as `swift-mutator watch-test-processes`, or returns nil if it can't. That's
    /// SwiftMutator's own executable unless a test names another.
    static func start(executable: URL? = Bundle.main.executableURL) -> TestProcessWatcher? {
        guard let executable, let ends = makePipe() else { return nil }
        let watcher = Foundation.Process()
        watcher.executableURL = executable
        watcher.arguments = [WatchTestProcesses.configuration.commandName ?? ""]
        watcher.standardInput = FileHandle(fileDescriptor: ends.read, closeOnDealloc: false)
        // Not SwiftMutator's own: a `| tee` would wait for the watcher to end too.
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        // Not the project's folder, which a run removes and makes again.
        watcher.currentDirectoryURL = URL(fileURLWithPath: "/")
        do {
            try watcher.run()
        } catch {
            Foundation.close(ends.read)
            Foundation.close(ends.write)
            return nil
        }
        Foundation.close(ends.read)
        return TestProcessWatcher(writingTo: ends.write, process: watcher)
    }

    /// A pipe for a watcher. Both ends are closed on exec, so no process SwiftMutator starts holds the pipe open, which
    /// would keep the watcher waiting until that process ended; the watcher's standard input is a copy, which stays
    /// open. Writes never wait: a watcher that stopped reading mustn't hold up a test run. A message is shorter than
    /// `PIPE_BUF`, so it is written whole or not at all.
    static func makePipe() -> (read: Int32, write: Int32)? {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return nil }
        for end in ends {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK)
        #if os(macOS)
        // Once the watcher has gone, a write fails rather than raising SIGPIPE, even where it isn't ignored.
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        #endif
        return (ends[0], ends[1])
    }

    /// Tells the watcher that `process`, a test process, has started.
    func started(_ process: RecordedProcess) {
        send("+\(process.id) \(process.started)\n")
    }

    /// Tells the watcher that the test process `process` has ended, so it is never killed.
    func ended(_ process: Int32) {
        send("-\(process)\n")
    }

    /// Closes the pipe, which ends the watcher once it has killed the test processes still listed.
    func close() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Foundation.close(descriptor)
            descriptor = -1
        }
    }

    /// A message the watcher, having gone, or full, can't take is dropped.
    private func send(_ message: String) {
        lock.withLock {
            guard descriptor >= 0 else { return }
            let bytes = Array(message.utf8)
            while write(descriptor, bytes, bytes.count) < 0, errno == EINTR {}
        }
    }

    /// The watcher's side: reads `input` until it closes, then kills each test process still listed, with every process
    /// that one started.
    static func watch(readingFrom input: Int32) {
        var running: [Int32: RecordedProcess] = [:]
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending += buffer[..<count]
            while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                apply(String(decoding: pending[..<end], as: UTF8.self), to: &running)
                pending.removeSubrange(...end)
            }
        }
        for process in running.values {
            process.terminateIfRunning()
        }
    }

    /// Applies a message to the list of running test processes. One it can't read is ignored.
    private static func apply(_ message: String, to running: inout [Int32: RecordedProcess]) {
        let fields = message.dropFirst().split(separator: " ")
        switch (message.first, fields.count) {
        case ("+", 2):
            guard let id = Int32(fields[0]), let started = UInt64(fields[1]) else { return }
            running[id] = RecordedProcess(id: id, started: started)
        case ("-", 1):
            guard let id = Int32(fields[0]) else { return }
            running[id] = nil
        default:
            return
        }
    }
}
