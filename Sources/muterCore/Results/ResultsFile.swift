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
    /// Appends each of `lines`, of any kinds, as a line of its own, as `append` does, but written out in one write and
    /// synchronized once: once this returns true, they all survive. After a failure, any of them may be missing, and
    /// the last one written may be cut off.
    @discardableResult
    func append(contentsOf lines: [any Encodable]) -> Bool
    /// Closes the file, which releases its lock.
    func close()
}

extension ResultsRecording {
    /// One `append` after another, for a file with no faster way.
    @discardableResult
    func append(contentsOf lines: [any Encodable]) -> Bool {
        lines.allSatisfy { append($0) }
    }
}

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

extension ResultsFile {
    /// Every name `Opener.create` gives a results file, in the order it tries them, which is the order the runs that
    /// share a log folder started in.
    static let fileNames = (1...99).map(fileName)

    /// The name `Opener.create` gives the `number`th results file in a folder: `results.jsonl`, then `results-2.jsonl`
    /// … `results-99.jsonl`.
    static func fileName(_ number: Int) -> String {
        number == 1 ? "results.jsonl" : "results-\(number).jsonl"
    }

    /// Whether `name` is one `Opener.create` gives a results file, so names a results file in a run's log folder.
    static func isResultsFileName(_ name: String) -> Bool {
        fileNames.contains(name)
    }

    /// The name of the note a resumed session leaves in its own log folder. The note names the results file the
    /// session adds to, which stays in the first session's folder. The name is not a results file name and doesn't
    /// start with one, so a glob for results files never finds it.
    static let noteFileName = "resumed session.txt"

    /// The note the `session`th session of a resumed run leaves in its log folder: `path`, the results file it adds
    /// to, on the first line by itself, so that `find` can read it back, then what the folder is.
    static func note(pointingTo path: String, session: Int) -> String {
        """
        \(path)

        This folder holds the logs of session \(session) of a resumed run. The run's results are in the results file \
        above, in the first session's log folder. Give that file, or this folder, to swift-mutator report, or to \
        swift-mutator run --resume or --reuse.

        """
    }

    /// The results file `path` names: `path` itself, or the one results file in the run's log folder it names. A
    /// resumed session's folder holds no results file but a note naming the one it adds to, which is given instead.
    /// Anything that isn't a folder, a missing path included, is left for reading it to refuse.
    static func find(at path: String, using fileManager: FileSystemManager) throws -> String {
        try locate(at: path, using: fileManager).path
    }

    /// The results file `path` names, as `find` gives it, and whether a resumed session's note named it.
    static func locate(at path: String, using fileManager: FileSystemManager) throws -> (path: String, isNoted: Bool) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: path) else { return (path, false) }
        let present = Set(names)
        // In the order the runs started in, so results-10.jsonl comes after results-2.jsonl, and results.jsonl first.
        let found = fileNames.filter(present.contains)
        switch found.count {
        case 1:
            return (path.appendingPathComponent(found[0]), false)

        case 0:
            guard present.contains(noteFileName), let noted = notedFile(in: path, using: fileManager) else {
                throw ResultsFileError.noResultsFile(folder: path)
            }
            return (noted, true)

        default:
            throw ResultsFileError.severalResultsFiles(folder: path, names: found)
        }
    }

    /// The results file that the note in `folder`, a resumed session's log folder, names: the note's first line, if it
    /// is an absolute path to a file with a results file's name. Whether the file is there is left for reading it to
    /// refuse, which names the file. It is given without looking in it, so one note never leads to another.
    static func notedFile(in folder: String, using fileManager: FileSystemManager) -> String? {
        let note = folder.appendingPathComponent(noteFileName)
        guard let data = fileManager.contents(atPath: note), let text = String(data: data, encoding: .utf8),
              let firstLine = text.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("/"), isResultsFileName(firstLine.lastPathComponent) else {
            return nil
        }
        return firstLine
    }

    /// What trying to lock a results file or a run's marker (`RunMarker`) without waiting found (`probeLock(_:)`).
    enum LockProbe: Equatable {
        /// No other process held its lock, and this descriptor now does, for the caller to close, which releases it.
        case held(Int32)
        /// Another process holds its lock.
        case inUse
        /// Nothing is there to lock.
        case missing
        /// It couldn't be opened or locked, with this `errno`, which says nothing of whether another process holds it,
        /// as where flock isn't supported.
        case failed(Int32)
    }

    /// Tries to lock the file at `path` with flock, a results file or a run's marker (`RunMarker`), without waiting. A
    /// holder's record, `.<name>.holder`, says nothing here: only the lock shows a run that still holds the file. A
    /// run that tries to hold the file meanwhile is refused as for any holder, so the caller closes it as soon as it
    /// can.
    static func probeLock(_ path: String) -> LockProbe {
        // Opened to write if it can be, as the file's holders open it: where flock is emulated with fcntl locks, as on
        // a Linux NFS mount, an exclusive lock needs that, and one opened read-only gets EBADF. Neither truncates nor
        // writes it. O_NONBLOCK: something other than a file at that path never keeps the caller waiting.
        var descriptor = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == EACCES || errno == EROFS {
            descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return errno == ENOENT ? .missing : .failed(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            closeDescriptor(descriptor)
            return code == EWOULDBLOCK ? .inUse : .failed(code)
        }
        return .held(descriptor)
    }

    /// Whether `output` names the file at `results`, so saving a report there would replace it: the same path once
    /// symbolic links are resolved, or another name for the same file, as a different case gives on a
    /// case-insensitive volume.
    static func isSameFile(_ output: String, _ results: String) -> Bool {
        if resolved(output) == resolved(results) {
            return true
        }
        guard let outputIdentity = identity(of: output), let resultsIdentity = identity(of: results) else {
            return false
        }
        return outputIdentity == resultsIdentity
    }

    /// Where the holder of the results file at `path` records itself: `.<name>.holder` beside it, once symbolic links
    /// are resolved, so a run that reaches the file through a linked folder finds the same record. A hidden name
    /// that doesn't start with a results file name, so a glob for results files never finds it.
    static func holderPath(for path: String) -> String {
        let file = resolved(path)
        return file.deletingLastPathComponent.appending("/.\(file.lastPathComponent).holder")
    }

    /// Writes `holder`'s record to `holderPath`, through a file of its own that then replaces the record there, so a
    /// refused run reads the last holder's record or this one, never part of one. The replacing also takes the place of
    /// a record this user can't write, or of a link at that path. Only for a refused run's message, so a record that
    /// can't be written, as to a folder that can't be written to, stops nothing.
    private static func record(_ holder: LockHolder?, at holderPath: String) {
        guard let holder else { return }
        let temporary = "\(holderPath).\(holder.process)"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return }
        let bytes = Array(holder.line.utf8)
        let written = write(descriptor, bytes, bytes.count)
        closeDescriptor(descriptor)
        if written != bytes.count || rename(temporary, holderPath) != 0 {
            _ = unlink(temporary)
        }
    }

    /// The holder that the record at `holderPath` names: one on this host only while its process still runs with the
    /// recorded start, and one on another host as it is recorded. None is named in the moment between a run locking
    /// the file and recording itself, or if the holder couldn't record itself, as a SwiftMutator older than this one
    /// doesn't.
    private static func holder(recordedAt holderPath: String) -> ResultsFileError.Holder? {
        // O_NONBLOCK: something other than a file at that path never keeps the refusal waiting.
        let descriptor = open(holderPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { closeDescriptor(descriptor) }
        // A record is far shorter.
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var count = read(descriptor, &buffer, buffer.count)
        while count < 0, errno == EINTR {
            count = read(descriptor, &buffer, buffer.count)
        }
        guard count > 0, let holder = LockHolder(record: String(lossyUTF8: buffer[..<count])[...])
        else { return nil }
        guard holder.isOnThisHost else { return .unchecked(holder) }
        return holder.stillRuns ? .running(holder) : nil
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The device and inode of the file at `path`, if there is one.
    private static func identity(of path: String) -> (device: dev_t, inode: ino_t)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }
}

/// close(2), which inside `ResultsFile` its own `close()` hides.
private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}
