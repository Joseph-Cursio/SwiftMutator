import Foundation
@testable import muterCore
import XCTest

extension LogFolderPruningTests {
    func prune(keeping: Int, now: Date = Date()) -> LogFolderPruning {
        LogFolderPruning.prune(root: root, current: [current], protected: [], keeping: keeping, now: now)
    }

    /// What is left in the root, sorted.
    func remaining() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    }

    /// Makes the log folder `name` in the root, dated `minutes` after `start`, with a kept log, and, as asked, the
    /// run's marker, a results file whose header names `header` (the folder itself, by default), and a resumed
    /// session's note naming `note`.
    @discardableResult
    func folder(
        _ name: String,
        at minutes: Double,
        marker: Bool = true,
        results: Bool = true,
        header named: String? = nil,
        mutant: String? = nil,
        shard: Int? = nil,
        note: String? = nil,
        stopped: Bool = false
    ) throws -> String {
        let path = root + "/" + name
        try write("a log", to: path + "/baseline run.log")
        if marker {
            try write("", to: path + "/" + RunMarker.fileName)
        }
        if results {
            try write(header(naming: named ?? path, mutant: mutant, shard: shard), to: path + "/results.jsonl")
        } else if stopped {
            let line = ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")
            try write(String(lossyUTF8: try resultsFileData([line])), to: path + "/results.jsonl")
        }
        if let note {
            try write(ResultsFile.note(pointingTo: note, session: 2), to: path + "/" + ResultsFile.noteFileName)
        }
        try setDates(of: path, to: minutes)
        return path
    }

    /// A results file's header line naming `logDirectory`.
    func header(naming logDirectory: String, mutant: String? = nil, shard: Int? = nil) throws -> String {
        let selection = shard.map {
            ShardSelection(
                index: $0,
                count: 4,
                mutantsInAllShards: 8,
                mutantsPerShard: [2, 2, 2, 2],
                allKeysSHA256: ""
            )
        }
        let line = ResultsHeader.make(logDirectory: logDirectory, shard: selection, mutant: mutant)
        return String(lossyUTF8: try resultsFileData([line]))
    }

    /// Dates `path`, and everything in it, `minutes` after `start`: their modification and creation dates.
    func setDates(of path: String, to minutes: Double) throws {
        let date = start.addingTimeInterval(minutes * 60)
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: path)) ?? []
        // The folder last, as dating what is in it changes nothing, but writing would.
        for item in names.map({ path + "/" + $0 }) + [path] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item)
            try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: item)
        }
    }

    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path.deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
}
