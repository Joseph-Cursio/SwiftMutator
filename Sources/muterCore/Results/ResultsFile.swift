import Foundation

/// Where mutation testing writes its results as it goes, one line at a time.
protocol ResultsRecording: AnyObject {
    var path: String { get }
    /// Why an append failed. After a failure nothing more is written.
    var writeError: Error? { get }
    /// Appends `line` as one line, written out in full and then synchronized with fsync. Once this returns true,
    /// the line survives SwiftMutator being killed, and an OS crash.
    @discardableResult
    func append(_ line: some Encodable) -> Bool
    /// Closes the file, which releases its lock.
    func close()
}

/// Makes a run's results file.
protocol ResultsFileOpening {
    /// A new file in `directory`: `results.jsonl`, or `results-2.jsonl` … `results-99.jsonl` if a run that started
    /// in the same minute has one there. Never an existing file.
    func create(in directory: String) throws -> ResultsRecording
}

enum ResultsFileError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(path: String, errno: Int32)
    /// Another SwiftMutator process holds its lock.
    case inUse(path: String)
    case cannotWrite(path: String, errno: Int32)
    case notAResultsFile(path: String)
    case newerFormat(path: String, version: Int)

    var description: String {
        switch self {
        case let .cannotOpen(path, code):
            return "can't open \(path): \(String(cString: strerror(code)))"
        case let .inUse(path):
            return "\(path) is in use by another SwiftMutator run"
        case let .cannotWrite(path, code):
            return "can't write to \(path): \(String(cString: strerror(code)))"
        case let .notAResultsFile(path):
            return "\(path) isn't a SwiftMutator results file: it has no header line"
        case let .newerFormat(path, version):
            return "\(path) is in results format \(version), which only a newer SwiftMutator can read"
        }
    }
}

/// A run's results file, opened for appending and locked with flock while it is open, so no second SwiftMutator
/// process writes to it. The kernel releases the lock when the process exits, SIGKILL included, so it never goes
/// stale: the descriptor is closed on exec, so no test process SwiftMutator starts keeps it, or its lock, open.
final class ResultsFile: ResultsRecording {
    struct Opener: ResultsFileOpening {
        func create(in directory: String) throws -> ResultsRecording {
            var path = directory
            for number in 1...99 {
                path = (directory as NSString).appendingPathComponent(
                    number == 1 ? "results.jsonl" : "results-\(number).jsonl"
                )
                // O_EXCL: a run that started in the same minute keeps its file.
                let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
                guard descriptor >= 0 else {
                    let code = errno
                    if code == EEXIST { continue }
                    throw ResultsFileError.cannotOpen(path: path, errno: code)
                }
                return try ResultsFile(descriptor: descriptor, path: path)
            }
            throw ResultsFileError.cannotOpen(path: path, errno: EEXIST)
        }
    }

    let path: String
    private(set) var writeError: Error?
    private var descriptor: Int32
    private let encoder = ResultsCoding.encoder
    /// write(2) and fsync(2); a test passes ones that fail.
    private let writeBytes: (Int32, UnsafeRawPointer, Int) -> Int
    private let synchronize: (Int32) -> Int32

    /// Takes over `descriptor`, open for appending to `path`, and locks it. A descriptor it can't lock is closed.
    init(
        descriptor: Int32,
        path: String,
        writeBytes: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { write($0, $1, $2) },
        synchronize: @escaping (Int32) -> Int32 = { fsync($0) }
    ) throws {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            closeDescriptor(descriptor)
            throw code == EWOULDBLOCK
                ? ResultsFileError.inUse(path: path)
                : ResultsFileError.cannotOpen(path: path, errno: code)
        }
        self.descriptor = descriptor
        self.path = path
        self.writeBytes = writeBytes
        self.synchronize = synchronize
    }

    deinit {
        close()
    }

    @discardableResult
    func append(_ line: some Encodable) -> Bool {
        guard writeError == nil, descriptor >= 0 else { return false }
        do {
            var data = try encoder.encode(line)
            data.append(UInt8(ascii: "\n"))
            try writeAll(data)
            try synchronizeToDisk()
            return true
        } catch {
            // The line may be half written, and nothing may follow it on the same line.
            writeError = error
            return false
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        closeDescriptor(descriptor)
        descriptor = -1
    }

    /// Writes all of `data`, however many writes it takes. A write a signal interrupted is tried again.
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let start = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = writeBytes(descriptor, start + written, buffer.count - written)
                if result > 0 {
                    written += result
                    continue
                }
                // A regular file never takes 0 of a non-empty write; were it to, trying again would loop forever.
                let code = result < 0 ? errno : EIO
                guard code == EINTR else { throw ResultsFileError.cannotWrite(path: path, errno: code) }
            }
        }
    }

    private func synchronizeToDisk() throws {
        while synchronize(descriptor) != 0 {
            let code = errno
            guard code == EINTR else { throw ResultsFileError.cannotWrite(path: path, errno: code) }
        }
    }
}

/// close(2), which inside `ResultsFile` its own `close()` hides.
private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}
