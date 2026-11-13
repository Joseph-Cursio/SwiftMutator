import Foundation

/// Reads a pipe to its end on a thread of its own, keeping what it has read so far, so a caller can stop waiting for
/// a pipe that some process holds open.
final class PipeReader: @unchecked Sendable { // `received` is behind `lock`
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
