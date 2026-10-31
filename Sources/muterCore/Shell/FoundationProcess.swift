import Foundation

extension Foundation.Process: MuterProcess {}

extension Foundation.Process {
    /// What `url` with `arguments` wrote to standard output, as `runCommand` runs it with no time limit, or nil if it
    /// couldn't be started. Its exit status is then `terminationStatus`.
    func runProcess(
        url: String,
        arguments args: [String]
    ) async -> Data? {
        await runCommand(url: url, arguments: args, timeLimit: nil).map { Data($0.output.utf8) }
    }

    /// How long the output of a command killed at its time limit is waited for. Killing the command's tree closes
    /// its standard output at once, unless a process that escaped the kill, as one whose parent had already exited,
    /// still holds it.
    private static let outputWaitAfterTimeLimit: TimeInterval = 1

    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) async -> CommandResult? {
        // Standard error goes to a file: a command that filled its pipe while standard output was being read would
        // never exit.
        let errorsURL = FileManager.default.temporaryDirectory.appendingPathComponent("muter-\(UUID().uuidString).err")
        guard FileManager.default.createFile(atPath: errorsURL.path, contents: nil),
              let errorsFile = try? FileHandle(forWritingTo: errorsURL)
        else { return nil }
        defer {
            try? errorsFile.close()
            try? FileManager.default.removeItem(at: errorsURL)
        }
        let output = Pipe()
        standardOutput = output
        standardError = errorsFile
        executableURL = URL(fileURLWithPath: url)
        arguments = args
        // Recorded as soon as Foundation reaps the process, so the time limit never kills a process that has exited,
        // whose ID the system may give to another process. Waiting for the handler holds no thread.
        let ending = TestRunEnding()
        let exited = Latch()
        terminationHandler = ending.recordingExit(opening: exited)
        // Not `try?` then a read: a command that can't be started leaves the pipe open at this end, so the read
        // would never return.
        do { try runWithNoSignalBlocked() } catch { return nil }
        if let timeLimit {
            // Not counting the time SwiftMutator was suspended, by Ctrl-Z, with the command.
            @Dependency(\.suspensions) var suspensions: Suspensions
            // The whole tree, not just the command: the test processes `swift test` starts would go on running.
            suspensions.after(timeLimit, on: .global(qos: .userInitiated)) {
                if ending.recordTimeLimit(of: self) { self.terminateTree() }
            }
        }
        // Read while the command runs: one that filled the pipe would never exit.
        let reader = PipeReader(output.fileHandleForReading)
        await exited.wait()
        let timedOut = ending.reason == .timedOut
        let outputData = await reader.data(waitingAtMost: timedOut ? Self.outputWaitAfterTimeLimit : nil)
        let errorsData = FileManager.default.contents(atPath: errorsURL.path) ?? Data()
        return CommandResult(
            status: terminationStatus,
            endedBySignal: terminationReason == .uncaughtSignal,
            output: String(decoding: outputData, as: UTF8.self),
            errors: String(decoding: errorsData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// Reads a pipe to its end on a thread of its own, keeping what it has read so far, so a caller can stop waiting for
/// a pipe that some process holds open.
private final class PipeReader: @unchecked Sendable { // `received` is behind `lock`
    private let lock = NSLock()
    private var received = Data()
    private let ended = Latch()

    /// The thread holds on to `handle`, so its file descriptor isn't closed, and given to another file, while the
    /// thread still reads it.
    init(_ handle: FileHandle) {
        Thread.detachNewThread { [self] in
            // Not `FileHandle.read(upToCount:)`, which on a pipe waits for the whole count, so what is read so far
            // would miss the last of it.
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                lock.withLock { received.append(contentsOf: buffer[..<count]) }
            }
            ended.open()
        }
    }

    /// Everything written to the pipe once it closes, or what was written by `timeout` seconds from now if it is
    /// still open then.
    func data(waitingAtMost timeout: TimeInterval?) async -> Data {
        if let timeout {
            await ended.wait(atMost: timeout)
        } else {
            await ended.wait()
        }
        return lock.withLock { received }
    }
}
