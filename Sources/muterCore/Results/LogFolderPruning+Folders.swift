import Foundation

extension LogFolderPruning {
    /// A file's device and inode, which tell whether two paths name one file, however each is spelled.
    struct FileIdentity: Hashable {
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

    /// The shard a results file's first header names (`HeaderInfo`).
    struct ShardInfo: Decodable {
        let index: Int
        let count: Int
    }

    /// What the pruner reads of a results file's first header, or of the `stopped` line that is the only line of a run
    /// that stopped before its first mutant (`ResultsStopped`), which names its folder as a header does.
    struct HeaderInfo: Decodable {
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
    struct Unit {
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
            header = headers.first.flatMap(\.self)
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
            ].compactMap(\.self)
        }
    }

    /// The folders of one run: a first session's, and each resumed session's whose note names its results file.
    struct Group {
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
