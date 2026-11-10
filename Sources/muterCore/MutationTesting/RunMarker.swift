import Foundation

/// The hidden file `.swiftmutator-run` in a run's log folder, which the run makes as it claims the folder and holds an
/// exclusive flock on until it exits. So a run that prunes log folders (`keepLogFolders:`, see `LogFolderPruning`)
/// leaves the folder of every run still going alone: a long baseline's, which has no results file to lock yet, a
/// `--mutant` run's beside a whole run, and one writing its report once its results file is closed. The kernel
/// releases the lock when the process exits, SIGKILL included, so it never goes stale, and the descriptor is closed on
/// exec, so no test process SwiftMutator starts keeps it, or its lock, open.
///
/// The file stays once the run has ended, and marks the folder as one SwiftMutator made. A folder that holds nothing
/// else is empty, as far as a run that removes its folder when it kept nothing in it is concerned. `report`,
/// `--resume` and `--reuse` look in a folder only for the files they name, so never at it.
final class RunMarker {
    /// The marker's name in a run's log folder.
    static let fileName = ".swiftmutator-run"

    /// The marker's path.
    let path: String
    private var descriptor: Int32

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        release()
    }

    /// The marker in `folder`, made if it isn't there and locked; nil when it can't be made or locked, as in a folder
    /// that isn't there. That stops nothing: a folder with no marker is pruned only once it holds a results file, which
    /// its run holds a lock on while it writes it.
    static func hold(in folder: String) -> RunMarker? {
        let markerPath = folder.appendingPathComponent(fileName)
        let openDescriptor = open(markerPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard openDescriptor >= 0 else { return nil }
        guard flock(openDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(openDescriptor)
            return nil
        }
        return RunMarker(descriptor: openDescriptor, path: markerPath)
    }

    /// Releases the lock. Done when the marker goes, and once the run's folder is removed.
    func release() {
        guard descriptor >= 0 else { return }
        _ = close(descriptor)
        descriptor = -1
    }
}

/// Shared flocks on the log folders of the run a `--reuse` reads, held until the reusing run exits, so a run that
/// prunes log folders (`LogFolderPruning`) leaves them alone: the reusing run copies its kept logs from them long after
/// it read their results file, and holds no other lock on them. A pruning run of the same project is refused by the
/// project's lock long before, but a test plan's run, which locks the copy its plan names, may prune the same folders.
///
/// It locks each folder's marker (`RunMarker`), and, in the results file's own folder if it has no marker, as one an
/// older SwiftMutator made, the results file. A shared lock stops neither a reader nor another reuse: only a pruning
/// run's exclusive one. What can't be opened or locked is left unlocked, which stops nothing: a run still going holds
/// its own marker's lock.
final class ReusedFolders: @unchecked Sendable { // `descriptors` changes only in `init` and `deinit`
    private let descriptors: [Int32]

    /// Locks the log folders `folders` of the run whose results file is at `resultsFile`.
    init(holding folders: [String], resultsFile: String) {
        let resultsFolder = resultsFile.deletingLastPathComponent
        let paths = folders.map { folder in
            let marker = folder.appendingPathComponent(RunMarker.fileName)
            var info = stat()
            let standardized = folder.standardizingPath
            let isResultsFolder = standardized == resultsFolder.standardizingPath
            return lstat(marker, &info) != 0 && isResultsFolder ? resultsFile : marker
        }
        descriptors = paths.compactMap(Self.lockShared(_:))
    }

    deinit {
        descriptors.forEach { _ = close($0) }
    }

    /// A descriptor holding a shared flock on the file at `path`, or nil when it can't be opened or locked.
    private static func lockShared(_ path: String) -> Int32? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            _ = close(descriptor)
            return nil
        }
        return descriptor
    }
}
