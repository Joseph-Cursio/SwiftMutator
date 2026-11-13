import Foundation

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
    static func record(_ holder: LockHolder?, at holderPath: String) {
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
    static func holder(recordedAt holderPath: String) -> ResultsFileError.Holder? {
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
