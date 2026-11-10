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
}

extension LogFolderPruning {
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
    ) -> LogFolderPruning {
        var pruning = LogFolderPruning(root: root, keeping: keeping)
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

extension LogFolderPruning {
    /// A file's device and inode, which tell whether two paths name one file, however each is spelled.
    private struct FileIdentity: Hashable {
        let device: Int64
        let inode: UInt64

        /// The identity of the file at `path`, following symbolic links; nil if there is none.
        init?(of path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = Int64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(truncatingIfNeeded: info.st_ino)
        }
    }

    /// What the pruner reads of a results file's first header, or of the `stopped` line that is the only line of a run
    /// that stopped before its first mutant (`ResultsStopped`), which names its folder as a header does.
    private struct HeaderInfo: Decodable {
        struct ShardInfo: Decodable {
            let index: Int
            let count: Int
        }

        let kind: String
        let logDirectory: String?
        let mutant: String?
        let shard: ShardInfo?

        /// The longest first line read: a header's list of the project's files takes about 140 bytes a file.
        static let longestLine = 64 * 1_024 * 1_024

        /// The first line of the results file at `path`, as a header; nil if it isn't one, or can't be read.
        init?(ofResultsFileAt path: String) {
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            defer { _ = close(descriptor) }
            var line = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            reading: while line.count < Self.longestLine {
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                if let end = buffer[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                    line.append(contentsOf: buffer[..<end])
                    break reading
                }
                line.append(contentsOf: buffer[..<count])
            }
            guard let header = try? JSONDecoder().decode(Self.self, from: line),
                  header.kind == "header" || header.kind == "stopped"
            else {
                return nil
            }
            self = header
        }
    }

    /// A folder directly in the root that holds something, as the pruner found it.
    private struct Unit {
        let name: String
        let path: String
        let identity: FileIdentity
        let entries: Set<String>
        /// Its results files' names, in the order their runs started in.
        let resultsFiles: [String]
        /// The first results file's first header.
        let header: HeaderInfo?
        /// The folder of the results file its note names, if it holds a resumed session's note and that file is there.
        let notedFolder: FileIdentity?
        /// Whether `notedFolder` is directly in the root.
        let notesAFolderInRoot: Bool
        /// Whether SwiftMutator made it, as far as it shows by itself: it has a run's marker, or a results file whose
        /// header names it. A resumed session's folder an older SwiftMutator made shows it only by its note.
        let isMarkedOrNamed: Bool
        let date: Date

        /// The folder `name` in `root`: nil unless it is a folder, not a link to one, and holds something.
        init?(named name: String, in root: String) {
            let entryPath = root.appendingPathComponent(name)
            guard Self.type(of: entryPath) == S_IFDIR,
                  let entryIdentity = FileIdentity(of: entryPath),
                  let listed = try? FileManager.default.contentsOfDirectory(atPath: entryPath),
                  !listed.isEmpty
            else { return nil }
            let entryNames = Set(listed)
            let resultsFileNames = ResultsFile.fileNames.filter(entryNames.contains)
            let inFolder = { (name: String) in entryPath.appendingPathComponent(name) }
            let headers = resultsFileNames.map { HeaderInfo(ofResultsFileAt: inFolder($0)) }
            let namesItself = headers.contains { header in
                header?.logDirectory.flatMap(FileIdentity.init(of:)) == entryIdentity
            }
            self.name = name
            self.path = entryPath
            self.identity = entryIdentity
            self.entries = entryNames
            self.resultsFiles = resultsFileNames
            header = headers.first.flatMap { $0 }
            isMarkedOrNamed = entryNames.contains(RunMarker.fileName) || namesItself
            let noted = entryNames.contains(ResultsFile.noteFileName) ? Self.notedFolder(of: entryPath, in: root) : nil
            notedFolder = noted?.identity
            notesAFolderInRoot = noted.map { folder in
                Self.parent(of: folder.path).flatMap(FileIdentity.init(of:)) == FileIdentity(of: root)
            } ?? false
            // Each written once, or only by its run: never the folder's own modification date.
            let created = Self.dates(of: entryPath, [.creationDateKey])
            let written = ([RunMarker.fileName, ResultsFile.noteFileName, RunSummary.fileName] + resultsFileNames)
                .filter(entryNames.contains)
                .flatMap { Self.dates(of: inFolder($0), [.contentModificationDateKey]) }
            date = (created + written).max() ?? .distantPast
        }

        /// The units SwiftMutator made, of `units`: those that show it by themselves, and those whose note names a
        /// results file in one of them.
        static func owned(_ units: [Self]) -> [Self] {
            let shown = Set(units.filter(\.isMarkedOrNamed).map(\.identity))
            return units.filter { unit in
                unit.isMarkedOrNamed || unit.notedFolder.map { shown.contains($0) } == true
            }
        }

        /// The folder, and its identity, of the results file that the note in `folder` names, if that file is there.
        /// A note names it by its full path, so once the root has moved, it is looked for under the same folder's and
        /// file's names in `root`.
        private static func notedFolder(of folder: String, in root: String) -> (path: String, identity: FileIdentity)? {
            guard let noted = ResultsFile.notedFile(in: folder, using: FileManager.default) else { return nil }
            let folderOfNoted = noted.deletingLastPathComponent
            let moved = root.appendingPathComponent(folderOfNoted.lastPathComponent)
            for candidate in [folderOfNoted, moved] {
                let file = candidate.appendingPathComponent(noted.lastPathComponent)
                if Self.type(of: file) == S_IFREG, let candidateIdentity = FileIdentity(of: candidate) {
                    return (candidate, candidateIdentity)
                }
            }
            return nil
        }

        private static func parent(of path: String) -> String? {
            let parent = path.deletingLastPathComponent
            return parent.isEmpty || parent == path ? nil : parent
        }

        /// The files whose locks show a run still uses the folder: its marker and its results files.
        var lockedFiles: [String] {
            ((entries.contains(RunMarker.fileName) ? [RunMarker.fileName] : []) + resultsFiles)
                .map { path.appendingPathComponent($0) }
        }

        /// Whether an older SwiftMutator, which made no marker, may still be testing here: its `running/` holds a run's
        /// output written to within `unmarkedFolderBusyInterval`.
        func isBusyWithoutMarker(now: Date) -> Bool {
            let running = path.appendingPathComponent(PerformMutationTesting.testOutputFolderName)
            guard !entries.contains(RunMarker.fileName),
                  let outputs = try? FileManager.default.contentsOfDirectory(atPath: running),
                  !outputs.isEmpty
            else { return false }
            let written = Self.dates(of: running, [.contentModificationDateKey, .creationDateKey]).max() ?? .distantPast
            return now.timeIntervalSince(written) < LogFolderPruning.unmarkedFolderBusyInterval
        }

        /// The entries SwiftMutator doesn't write, by their paths in the folder. It writes kept logs, results files and
        /// their holders' records, a resumed session's note, `summary.json`, its marker and `running/`, which holds
        /// only files; macOS's `.DS_Store` is allowed too.
        var foreignEntries: [String] {
            entries.sorted().flatMap { entry -> [String] in
                let entryPath = path.appendingPathComponent(entry)
                if entry == PerformMutationTesting.testOutputFolderName, Self.type(of: entryPath) == S_IFDIR {
                    let outputs = ((try? FileManager.default.contentsOfDirectory(atPath: entryPath)) ?? []).sorted()
                    return outputs
                        .filter { Self.type(of: entryPath.appendingPathComponent($0)) != S_IFREG }
                        .map { "\(entry)/\($0)" }
                }
                return Self.type(of: entryPath) == S_IFREG && Self.isWrittenBySwiftMutator(entry) ? [] : [entry]
            }
        }

        /// The space the folder's files take on disk.
        var allocatedBytes: Int64 {
            let running = path.appendingPathComponent(PerformMutationTesting.testOutputFolderName)
            let outputs = ((try? FileManager.default.contentsOfDirectory(atPath: running)) ?? [])
                .map { running.appendingPathComponent($0) }
            return (entries.map { path.appendingPathComponent($0) } + outputs)
                .reduce(0) { $0 + Self.allocatedBytes(of: $1) }
        }

        /// Whether SwiftMutator writes a file named `name` in a log folder.
        private static func isWrittenBySwiftMutator(_ name: String) -> Bool {
            let fixed = [RunMarker.fileName, ResultsFile.noteFileName, RunSummary.fileName, ".DS_Store"]
            if fixed.contains(name) || name.hasSuffix(".log") || ResultsFile.isResultsFileName(name) {
                return true
            }
            // `.<results>.holder`, and `.<results>.holder.<process>` as it is written.
            return ResultsFile.fileNames.contains { results in
                let holder = ".\(results).holder"
                guard name.hasPrefix(holder) else { return false }
                let rest = name.dropFirst(holder.count)
                return rest.isEmpty || (rest.first == "." && rest.count > 1 && rest.dropFirst().allSatisfy(\.isNumber))
            }
        }

        /// The file type of `path` itself, a symbolic link not followed: `S_IFDIR`, `S_IFREG`, `S_IFLNK` and so on;
        /// nil if there is nothing there.
        private static func type(of path: String) -> mode_t? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return info.st_mode & S_IFMT
        }

        private static func allocatedBytes(of path: String) -> Int64 {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { return 0 }
            return Int64(info.st_blocks) * 512
        }

        /// The dates `keys` name of the file at `path`, those there are: its modification and creation dates.
        private static func dates(of path: String, _ keys: Set<URLResourceKey>) -> [Date] {
            guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return [] }
            return [
                keys.contains(.contentModificationDateKey) ? values.contentModificationDate : nil,
                keys.contains(.creationDateKey) ? values.creationDate : nil,
            ].compactMap { $0 }
        }
    }

    /// The folders of one run: a first session's, and each resumed session's whose note names its results file.
    private struct Group {
        let members: [Unit]

        /// The newest of its folders' dates.
        var date: Date {
            members.map(\.date).max() ?? .distantPast
        }

        /// The first of its folders' paths, which orders groups with the same date.
        var firstPath: String {
            members.map(\.path).min() ?? ""
        }

        /// Whether it is a run that counts toward the newest kept: it holds a results file whose first header isn't a
        /// `--mutant` run's. A file whose header can't be read counts as one, so it is never removed sooner. A file
        /// that says only why its run stopped before its first mutant doesn't: it holds no result, as a run whose
        /// baseline failed held no file before such files.
        var isRun: Bool {
            guard members.contains(where: { !$0.resultsFiles.isEmpty }) else { return false }
            return firstHeader?.kind != "stopped" && firstHeader?.mutant == nil
        }

        /// The shard its first session tested, if it tested one.
        var shard: Shard? {
            firstHeader?.shard.map { Shard(index: $0.index, count: $0.count) }
        }

        private var firstHeader: HeaderInfo? {
            members.lazy.compactMap(\.header).first
        }

        /// `units` grouped: a resumed session's folder joins the folder whose results file its note names. Each
        /// group's folders are oldest first.
        static func grouping(_ units: [Unit]) -> [Self] {
            var leader = Array(units.indices)
            func root(of index: Int) -> Int {
                var index = index
                while leader[index] != index {
                    index = leader[index]
                }
                return index
            }
            let byIdentity = Dictionary(units.enumerated().map { ($1.identity, $0) }) { first, _ in first }
            for (index, unit) in units.enumerated() {
                guard let noted = unit.notedFolder, let target = byIdentity[noted] else { continue }
                leader[root(of: index)] = root(of: target)
            }
            return Dictionary(grouping: units.indices, by: root(of:))
                .values
                .map { indices in Self(members: indices.map { units[$0] }.sorted { $0.date < $1.date }) }
        }
    }
}
