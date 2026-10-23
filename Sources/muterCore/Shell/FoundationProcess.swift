import Foundation

extension Foundation.Process: MuterProcess {}

extension Foundation.Process {
    #if !os(Linux)
    @objc
    #endif
    var processData: Data? {
        (standardOutput as? Pipe)?.readStringToEndOfFile()
    }

    func runProcess(
        url: String,
        arguments args: [String]
    ) -> Data? {
        let pipe = Pipe()
        standardOutput = pipe
        standardError = FileHandle.nullDevice
        executableURL = URL(fileURLWithPath: url)
        arguments = args

        try? run()

        let output = processData

        pipe.fileHandleForReading.closeFile()

        waitUntilExit()

        return output
    }

    /// How long the output of a command killed at its time limit is waited for. Killing the command's tree closes
    /// its standard output at once, unless a process that escaped the kill, as one whose parent had already exited,
    /// still holds it.
    private static let outputWaitAfterTimeLimit: TimeInterval = 1

    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) -> CommandResult? {
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
        // whose ID the system may give to another process.
        let ending = TestRunEnding()
        terminationHandler = { _ in _ = ending.record(.exited) }
        // Not `try?` then a read: a command that can't be started leaves the pipe open at this end, so the read
        // would never return.
        do { try run() } catch { return nil }
        if let timeLimit {
            // The whole tree, not just the command: the test processes `swift test` starts would go on running.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeLimit) {
                if ending.record(.timedOut) { self.terminateTree() }
            }
        }
        // Read while the command runs: one that filled the pipe would never exit.
        let reader = PipeReader(output.fileHandleForReading)
        waitUntilExit()
        // For an exit `terminationHandler` hasn't recorded yet: once the process is gone, the limit mustn't kill it.
        _ = ending.record(.exited)
        let timedOut = ending.reason == .timedOut
        let outputData = reader.data(waitingAtMost: timedOut ? Self.outputWaitAfterTimeLimit : nil)
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
    private let ended = DispatchSemaphore(value: 0)

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
            ended.signal()
        }
    }

    /// Everything written to the pipe once it closes, or what was written by `timeout` seconds from now if it is
    /// still open then.
    func data(waitingAtMost timeout: TimeInterval?) -> Data {
        if let timeout {
            _ = ended.wait(timeout: .now() + timeout)
        } else {
            ended.wait()
        }
        return lock.withLock { received }
    }
}

private extension Pipe {
    func readStringToEndOfFile() -> Data? {
        let data: Data
        if #available(OSX 10.15.4, *) {
            data = (try? fileHandleForReading.readToEnd()) ?? Data()
        } else {
            data = fileHandleForReading.readDataToEndOfFile()
        }

        return data
    }
}
