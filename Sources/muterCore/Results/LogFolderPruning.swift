import Foundation

/// What a run's pruning of `<project>_muter_logs` did (`keepLogFolders:`): the earlier runs whose log folders it
/// removed, how much that freed, and those it left, and why.
///
/// It keeps the newest `keeping` runs, this one included, so the run before this one is always kept:
/// - **A run** is the folders of each of its sessions: a resumed session's folder joins the folder of the results file
///   its note names (`ResultsFile.noteFileName`). Each `--shard` is a run of its own.
/// - **Only runs count.** A group of folders counts only when it holds a results file whose first header isn't a
///   `--mutant` run's. Groups that don't, such as a run that stopped before its first mutant, whose results file has
///   only a `stopped` line, a `mutate-without-running` run and a `--mutant` run, are kept while they are newer than
///   the oldest earlier run kept, and removed once older. With no earlier run, none of them is removed.
/// - **The newest by date**, never by name: the newest of each folder's creation date, its marker's modification date,
///   and its results files', note's and `summary.json`'s modification dates. Never a folder's own modification date,
///   which moves whenever anything in it is made or removed, as when Finder writes `.DS_Store` there.
/// - **Never removed:** this run's folders, a resumed run's earlier ones included, and those of the run a `--reuse`
///   reads, which are kept besides the newest `keeping`.
/// - **Only SwiftMutator's folders:** one with a run's marker (`RunMarker`), one an older SwiftMutator made, holding a
///   results file whose header names that folder as its `logDirectory`, and a resumed session's folder an older
///   SwiftMutator made, whose note names a results file in one of those. Any other folder is never touched, nor said,
///   and nor is a resumed session's folder whose note names a results file in such a folder. An empty folder is left
///   too: another run may have just claimed it.
/// - **Left, and said:** a folder holding a file SwiftMutator doesn't write; one a run still uses, whose marker or
///   results file another process holds a lock on (a run writing it, or reusing its results, `ReusedFolders`), or,
///   with no marker, whose `running/` was written to in the last day; one whose locks can't be checked; and one that
///   can't be removed.
struct LogFolderPruning: Equatable, Sendable {
    /// An earlier run whose folders were removed.
    struct Removed: Equatable, Sendable {
        /// The folders' names in `root`, oldest first.
        let folders: [String]
        /// The shard its first session tested (`--shard`), if it tested one.
        let shard: Shard?
    }

    /// An earlier run, beyond the newest `keeping`, whose folders were left.
    struct Left: Equatable, Sendable {
        /// The folders' names in `root`, oldest first.
        let folders: [String]
        let reason: Reason
    }

    /// Why an earlier run's folders were left.
    enum Reason: Equatable, Sendable {
        /// Another run still uses them.
        case inUse
        /// Whether another run uses them couldn't be told, for this reason, as where flock isn't supported.
        case couldNotCheck(String)
        /// They hold these files, which SwiftMutator doesn't write, by their paths in their folder.
        case foreignFiles([String])
        /// Removing them failed, for this reason. Any folder named before it may be gone.
        case couldNotRemove(String)
    }

    /// The folder the log folders are in, `<project>_muter_logs`.
    let root: String
    /// `keepLogFolders`: how many runs are kept, this one included.
    let keeping: Int
    /// Oldest first.
    var removed: [Removed] = []
    /// How much space the removed folders took on disk.
    var freedBytes: Int64 = 0
    /// Oldest first.
    var left: [Left] = []

    /// Whether there is nothing to say: no run was beyond the newest `keeping`.
    var isEmpty: Bool {
        removed.isEmpty && left.isEmpty
    }

    /// How long a folder an older SwiftMutator made, which has no marker, counts as in use once its `running/` was
    /// last written to: no run of one mutant's tests takes a day.
    static let unmarkedFolderBusyInterval: TimeInterval = 24 * 60 * 60

    /// Prunes `root`, keeping the newest `keeping` runs, this one included. `current` names the folders of this run:
    /// its own and, for a resume, those of the run it continues. `protected` names the folders of the run a `--reuse`
    /// reads. Both are compared by file identity, however they are spelled. It never throws: what can't be read is
    /// left alone, and what can't be removed is said.
    static func prune(
        root: String,
        current: [String],
        protected: [String],
        keeping: Int,
        now: Date = Date()
    ) -> Self {
        var pruning = Self(root: root, keeping: keeping)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        let units = Unit.owned(names.compactMap { Unit(named: $0, in: root) })
        let identities = Set(units.map(\.identity))
        let kept = Set((current + protected).compactMap(FileIdentity.init(of:)))
        let groups = Group.grouping(units).filter { group in
            !group.members.contains { member in
                // A resumed session whose first session's folder isn't SwiftMutator's goes with nothing, and is left.
                kept.contains(member.identity)
                    || member.notedFolder.map { member.notesAFolderInRoot && !identities.contains($0) } == true
            }
        }
        for group in beyond(keeping: keeping, among: groups).reversed() {
            pruning.remove(group, now: now)
        }
        return pruning
    }

    /// The groups beyond the newest `keeping` runs, this one included, newest first: every run older than the oldest
    /// of the `keeping − 1` newest, and every group that isn't a run and is older than the oldest earlier run kept,
    /// whether or not there are more runs than are kept. None with no earlier run.
    private static func beyond(keeping: Int, among groups: [Group]) -> [Group] {
        let sorted = groups.sorted { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.firstPath < rhs.firstPath
        }
        let earlierRunsKept = max(keeping - 1, 1)
        let runs = sorted.indices.filter { sorted[$0].isRun }
        guard let oldestKept = runs.prefix(earlierRunsKept).last else { return [] }
        return Array(sorted[(oldestKept + 1)...])
    }

    /// Removes `group`'s folders, or says why it leaves them: it holds files SwiftMutator doesn't write, or another
    /// run uses it. Its locks are held only while its folders are removed.
    private mutating func remove(_ group: Group, now: Date) {
        let folders = group.members.map(\.name)
        let foreign = group.members.flatMap(\.foreignEntries)
        guard foreign.isEmpty else {
            left.append(Left(folders: folders, reason: .foreignFiles(foreign)))
            return
        }
        guard !group.members.contains(where: { $0.isBusyWithoutMarker(now: now) }) else {
            left.append(Left(folders: folders, reason: .inUse))
            return
        }
        let held: [Int32]
        switch Self.holdIdle(group.members.flatMap(\.lockedFiles)) {
        case let .success(descriptors):
            held = descriptors

        case let .failure(unheld):
            left.append(Left(folders: folders, reason: unheld.reason))
            return
        }
        defer { held.forEach { _ = close($0) } }
        var failures: [String] = []
        for member in group.members {
            let size = member.allocatedBytes
            if let failure = Self.removeFolder(atPath: member.path) {
                failures.append(failure)
            } else {
                freedBytes += size
            }
        }
        if failures.isEmpty {
            removed.append(Removed(folders: folders, shard: group.shard))
        } else {
            left.append(Left(folders: folders, reason: .couldNotRemove(failures.joined(separator: "; "))))
        }
    }

    /// Removes the folder at `path` and everything in it, and gives why it couldn't, or nil. A folder that has gone
    /// meanwhile is as good as removed.
    static func removeFolder(atPath path: String) -> String? {
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            var info = stat()
            return lstat(path, &info) == 0 ? error.localizedDescription : nil
        }
    }

    /// A descriptor locking each of `paths` that is there, or, with none held, why not: one is in use, or one couldn't
    /// be checked. Only a lock another process holds says it is in use.
    private static func holdIdle(_ paths: [String]) -> Result<[Int32], Unheld> {
        var held: [Int32] = []
        for path in paths {
            let reason: Reason
            switch ResultsFile.probeLock(path) {
            case let .held(descriptor):
                held.append(descriptor)
                continue

            case .missing:
                continue

            case .inUse:
                reason = .inUse

            case let .failed(code):
                reason = .couldNotCheck(String(cString: strerror(code)))
            }
            held.forEach { _ = close($0) }
            return .failure(Unheld(reason: reason))
        }
        return .success(held)
    }

    /// Why a group's locks weren't held.
    private struct Unheld: Error {
        let reason: Reason
    }
}
