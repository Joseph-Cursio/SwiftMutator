import Foundation

/// Makes a run's results file.
protocol ResultsFileOpening: Sendable {
    /// A new file in `directory`: `results.jsonl`, or `results-2.jsonl` … `results-99.jsonl` if the folder has one
    /// already. Never an existing file.
    func create(in directory: String) throws -> ResultsRecording
    /// The results file at `path`, opened to append another session and locked. Nothing is written until the first
    /// line is appended, and a last line cut off as it was written is ended just before it, so it stays a line of its
    /// own that readers skip. Never a new file.
    func openForResume(at path: String) throws -> ResultsRecording
}

enum ResultsFileError: Error, Equatable, CustomStringConvertible {
    case cannotOpen(path: String, errno: Int32)
    /// Another SwiftMutator process holds its lock: `holder`, if its record shows which.
    case inUse(path: String, holder: Holder?)
    case cannotWrite(path: String, errno: Int32)
    /// Nothing SwiftMutator can read is at `path`, as when it's missing.
    case unreadable(path: String)
    case notAResultsFile(path: String)
    /// The file records a run that stopped before its first mutant (`ResultsStopped`), so it has no result.
    case stoppedBeforeFirstMutant(path: String, ResultsStopped)
    case newerFormat(path: String, version: Int)
    /// A log folder holds no results file to make a report from.
    case noResultsFile(folder: String)
    /// A log folder holds a results file for each of several runs that started in the same minute, as a folder did
    /// before each run got one of its own.
    case severalResultsFiles(folder: String, names: [String])

    var description: String {
        switch self {
        case let .cannotOpen(path, code):
            return "can't open \(path): \(String(cString: strerror(code)))"

        case let .inUse(path, holder):
            switch holder {
            case let .running(holder):
                return "\(path) is in use by another SwiftMutator run (\(holder))"

            case let .unchecked(holder):
                return "\(path) is in use by another SwiftMutator run (\(holder), by its record, which this host "
                    + "can't check)"

            case nil:
                return "\(path) is in use by another SwiftMutator run"
            }

        case let .cannotWrite(path, code):
            return "can't write to \(path): \(String(cString: strerror(code)))"

        case let .unreadable(path):
            return "can't read \(path)"

        case let .notAResultsFile(path):
            return "\(path) isn't a SwiftMutator results file: it has no header line"

        case let .stoppedBeforeFirstMutant(path, stopped):
            return stopped.lines(path: path).joined(separator: "\n")

        case let .newerFormat(path, version):
            return "\(path) is in results format \(version), which only a newer SwiftMutator can read"

        case let .noResultsFile(folder):
            return "\(folder) holds no results file (results.jsonl)"

        case let .severalResultsFiles(folder, names):
            return "\(folder) holds \(names.count) results files, one for each run that started in that minute: "
                + names.joined(separator: ", ") + ". Pass the one you want."
        }
    }

    /// The holder of a results file's lock, as its record names it.
    enum Holder: Equatable, Sendable {
        /// A process on this host, which still runs with the recorded start.
        case running(LockHolder)
        /// A process on another host, which this host can't ask about.
        case unchecked(LockHolder)
    }
}

/// A run's results file, opened for appending and locked with flock while it is open, so no second SwiftMutator
/// process writes to it. The kernel releases the lock when the process exits, SIGKILL included, so it never goes
/// stale: the descriptor is closed on exec, so no test process SwiftMutator starts keeps it, or its lock, open.
///
/// The holder records its process ID, when it started and its host in `.<file>.holder` beside the file, and removes
/// that record as it closes the file, so a run that is refused can name it. flock itself can't say who holds it. A run
/// that ends without closing the file leaves its record, which names no one once that process has ended.
final class ResultsFile: ResultsRecording {
    struct Opener: ResultsFileOpening {
        func create(in directory: String) throws -> ResultsRecording {
            var filePath = directory
            for name in ResultsFile.fileNames {
                filePath = directory.appendingPathComponent(name)
                // O_EXCL: a file already there is kept.
                let openDescriptor = open(filePath, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
                guard openDescriptor >= 0 else {
                    let code = errno
                    if code == EEXIST { continue }
                    throw ResultsFileError.cannotOpen(path: filePath, errno: code)
                }
                return try ResultsFile(descriptor: openDescriptor, path: filePath)
            }
            throw ResultsFileError.cannotOpen(path: filePath, errno: EEXIST)
        }

        func openForResume(at path: String) throws -> ResultsRecording {
            // No O_CREAT: a results file that isn't there has nothing to resume.
            let openDescriptor = open(path, O_RDWR | O_APPEND | O_CLOEXEC)
            guard openDescriptor >= 0 else { throw ResultsFileError.cannotOpen(path: path, errno: errno) }
            // Locked at once, so a run still writing the file is refused. Its last line is ended only before the
            // session's first line: a resume that is refused, or whose baseline fails, leaves the file as it was,
            // and so does one of a file that isn't a results file at all.
            let file = try ResultsFile(descriptor: openDescriptor, path: path)
            file.endsLastLineFirst = true
            return file
        }
    }

    let path: String
    private(set) var writeError: Error?
    private var descriptor: Int32
    /// Where the holder's record is.
    private let holderPath: String
    /// Whether the file's last line is to be ended before the first line is appended: the file was opened to add a
    /// session to it, and an earlier one may have cut its last line off.
    private var endsLastLineFirst = false
    private let encoder = ResultsCoding.encoder
    /// write(2) and fsync(2); a test passes ones that fail.
    private let writeBytes: (Int32, UnsafeRawPointer, Int) -> Int
    private let synchronize: (Int32) -> Int32

    /// Takes over `descriptor`, open for appending to `path`, locks it and records the holder. A descriptor it can't
    /// lock is closed.
    init(
        descriptor: Int32,
        path: String,
        writeBytes: @escaping (Int32, UnsafeRawPointer, Int) -> Int = { write($0, $1, $2) },
        synchronize: @escaping (Int32) -> Int32 = { fsync($0) }
    ) throws {
        let holderFile = Self.holderPath(for: path)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            closeDescriptor(descriptor)
            throw code == EWOULDBLOCK
                ? ResultsFileError.inUse(path: path, holder: Self.holder(recordedAt: holderFile))
                : ResultsFileError.cannotOpen(path: path, errno: code)
        }
        Self.record(LockHolder.current(), at: holderFile)
        self.descriptor = descriptor
        self.path = path
        self.holderPath = holderFile
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
            if endsLastLineFirst {
                try endLastLine()
                endsLastLineFirst = false
            }
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

    @discardableResult
    func append(contentsOf lines: [any Encodable]) -> Bool {
        guard writeError == nil, descriptor >= 0 else { return false }
        guard !lines.isEmpty else { return true }
        do {
            if endsLastLineFirst {
                try endLastLine()
                endsLastLineFirst = false
            }
            var data = Data()
            for line in lines {
                data.append(try encoder.encode(line))
                data.append(UInt8(ascii: "\n"))
            }
            try writeAll(data)
            try synchronizeToDisk()
            return true
        } catch {
            // The lines may be half written, and nothing may follow them on the same line.
            writeError = error
            return false
        }
    }

    func close() {
        guard descriptor >= 0 else { return }
        // While the lock is still held, so it never removes the next holder's record.
        _ = unlink(holderPath)
        closeDescriptor(descriptor)
        descriptor = -1
    }

    /// Ends the file's last line with a line break if it lacks one, so the line appended next stands alone. It looks at
    /// the last byte, not at whether the last line reads: a whole last line without its break reads fine, and stays
    /// readable once it is ended.
    private func endLastLine() throws {
        let size = lseek(descriptor, 0, SEEK_END)
        guard size >= 0 else { throw ResultsFileError.cannotOpen(path: path, errno: errno) }
        guard size > 0 else { return }
        var last: UInt8 = 0
        guard pread(descriptor, &last, 1, size - 1) == 1 else {
            throw ResultsFileError.cannotOpen(path: path, errno: errno)
        }
        guard last != UInt8(ascii: "\n") else { return }
        try writeAll(Data([UInt8(ascii: "\n")]))
        try synchronizeToDisk()
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
func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}
