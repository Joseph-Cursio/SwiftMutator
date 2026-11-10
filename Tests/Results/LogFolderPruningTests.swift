import Foundation
@testable import muterCore
import XCTest

/// Pruning `<project>_muter_logs` (`keepLogFolders:`), on real folders: which runs it keeps, which it removes, and
/// which it leaves alone.
final class LogFolderPruningTests: MuterTestCase {
    private var root = ""
    /// This run's folder, which holds only its marker, as at the time pruning runs.
    private var current = ""
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeTemporaryDirectory() + "/x_muter_logs"
        current = try folder("Nov 3, 2026 at 9:00 AM", at: 10_000, results: false)
    }

    // By the folders' dates, not their names, which sort `Oct 10` before `Oct 9`.
    func test_keepsTheNewestRunsByDate_whenTheirNamesSortOtherwise() throws {
        try folder("Oct 9, 2026 at 9:00 AM", at: 0)
        try folder("Oct 9, 2026 at 9:00 AM (2)", at: 1)
        try folder("Oct 10, 2026 at 8:00 AM", at: 1_400)

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["Oct 9, 2026 at 9:00 AM"], ["Oct 9, 2026 at 9:00 AM (2)"]])
        XCTAssertEqual(pruning.left, [])
        XCTAssertGreaterThan(pruning.freedBytes, 0)
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "Oct 10, 2026 at 8:00 AM"])
    }

    // This run counts as one of the runs kept, so with 3 kept, 2 earlier ones are, and it is never removed, though at
    // this point it is the folder with the least in it.
    func test_thisRun_countsAsOne_andIsNeverRemoved() throws {
        try folder("a", at: 0)
        try folder("b", at: 10)
        try folder("c", at: 20)
        try setDates(of: current, to: -100)

        let pruning = prune(keeping: 3)

        XCTAssertEqual(pruning.removed.map(\.folders), [["a"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "b", "c"])
    }

    // While there are no more earlier runs than are kept, no run is removed, however old, but a folder that isn't a
    // run and is older than the oldest of them goes: failed baselines don't pile up while too few runs succeed.
    func test_noMoreRunsThanAreKept_removesNoRun_butOlderFoldersThatArent() throws {
        try folder("a", at: 0)
        try folder("older log only", at: -10, results: false)
        try folder("older mutant", at: -5, mutant: "RelationalOperatorReplacement @ A.swift:1:1")
        try folder("newer log only", at: 10, results: false)

        let pruning = prune(keeping: 3)

        XCTAssertEqual(pruning.removed.map(\.folders), [["older log only"], ["older mutant"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "a", "newer log only"])
    }

    // With no earlier run, there is no oldest run kept to go by, and nothing is removed.
    func test_noEarlierRun_removesNothing() throws {
        try folder("log only", at: -10, results: false)
        try folder("one mutant", at: -5, mutant: "RelationalOperatorReplacement @ A.swift:1:1")

        XCTAssertTrue(prune(keeping: 2).isEmpty)
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "log only", "one mutant"])
    }

    // A folder's own modification date moves whenever anything in it is made or removed, as when Finder writes
    // `.DS_Store` in an old run's folder, or a log is deleted from it: that doesn't make the run newer, so the run
    // before this one is still kept.
    func test_somethingMadeOrRemovedInAnOldRunsFolder_leavesItsDate() throws {
        let old = try folder("old", at: 0)
        try folder("before this one", at: 10)
        try write("x", to: old + "/.DS_Store")
        try FileManager.default.removeItem(atPath: old + "/baseline run.log")

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["old"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "before this one"])
    }

    // A run's resumed sessions go with it, dated by the newest: kept whole while that is new enough, removed whole once
    // it isn't.
    func test_aResumedRun_isKeptOrRemovedWhole_datedByItsNewestSession() throws {
        let first = try folder("first", at: 0)
        try folder("second", at: 300, results: false, note: first + "/results.jsonl")
        try folder("other", at: 200)

        XCTAssertEqual(prune(keeping: 2).removed.map(\.folders), [["other"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "first", "second"])

        try folder("newer", at: 400)
        XCTAssertEqual(prune(keeping: 2).removed.map(\.folders), [["first", "second"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "newer"])
    }

    // An older SwiftMutator made no marker, so its resumed session's folder holds only logs and the note. It is
    // SwiftMutator's by that note, which names a results file in a folder that is, and goes with that run.
    func test_anUnmarkedResumedSessionsFolder_goesWithTheRunItsNoteNames() throws {
        let first = try folder("first", at: 0, marker: false)
        try folder("second", at: 300, marker: false, results: false, note: first + "/results.jsonl")
        try folder("newer", at: 400)

        XCTAssertEqual(prune(keeping: 2).removed.map(\.folders), [["first", "second"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "newer"])
    }

    // A resumed session's folder whose note names a results file in a folder of the root that isn't SwiftMutator's
    // belongs to that folder's run, which is never touched: it is left too, not removed on its own, and not said.
    func test_aResumedSessionsFolder_whoseRunIsntSwiftMutatorsFolder_isLeft() throws {
        let elsewhere = try makeTemporaryDirectory()
        let first = try folder("first", at: 0, marker: false, header: elsewhere)
        try folder("second", at: 10, results: false, note: first + "/results.jsonl")
        try folder("kept", at: 100)
        try folder("newer", at: 200)

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["kept"]])
        XCTAssertEqual(pruning.left, [])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "first", "newer", "second"])
    }

    // A note names the results file by its full path, so once the whole root has moved, it names a file that isn't
    // there; the same folder and file in the root still are, and the session goes with that run.
    func test_aNoteFromBeforeTheRootMoved_findsItsRunInTheRoot() throws {
        let first = try folder("first", at: 0)
        try folder("second", at: 300, results: false, note: "/moved/x_muter_logs/first/results.jsonl")
        try folder("newer", at: 400)

        XCTAssertEqual(prune(keeping: 2).removed.map(\.folders), [["first", "second"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
    }

    // A note whose file isn't there, or is outside the root, joins its folder to no run: the folder isn't a run, and
    // newer than the run kept, it stays, while the old run it names goes.
    func test_aNoteNamingAMissingFileOrOneOutsideTheRoot_linksNothing() throws {
        let outside = try makeTemporaryDirectory()
        try write("", to: outside + "/results.jsonl")
        let old = try folder("old", at: 0)
        try folder("kept", at: 100)
        try folder("missing", at: 200, results: false, note: old + "/results-7.jsonl")
        try folder("outside", at: 210, results: false, note: outside + "/results.jsonl")

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["old"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "kept", "missing", "outside"])
    }

    // Folders without a run's results file don't count toward those kept: a run whose baseline failed doesn't push out
    // the last good run, nor does a `--mutant` run. They go once older than the oldest run kept.
    func test_logOnlyAndOneMutantRuns_dontCount_andGoOnceOlderThanTheOldestRunKept() throws {
        try folder("good", at: 0)
        try folder("failed baseline", at: 10, results: false)
        try folder("one mutant", at: 20, mutant: "RelationalOperatorReplacement @ A.swift:1:1")

        XCTAssertTrue(prune(keeping: 2).isEmpty)

        try folder("next", at: 30)
        try folder("newer mutant", at: 40, mutant: "RelationalOperatorReplacement @ A.swift:1:1")
        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["good"], ["failed baseline"], ["one mutant"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "newer mutant", "next"])
    }

    // A run that stopped before its first mutant leaves a file that says only why, which holds no result: it counts
    // no more than a run whose baseline failed did when that left no file, so stopped attempts never push out a run.
    func test_runsThatStoppedBeforeTheirFirstMutant_dontCount() throws {
        try folder("good", at: 0)
        try folder("stopped 1", at: 10, results: false, stopped: true)
        try folder("stopped 2", at: 20, results: false, stopped: true)

        XCTAssertTrue(prune(keeping: 2).isEmpty)
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "good", "stopped 1", "stopped 2"])
    }

    // A resume's earlier sessions are this run, and a reuse's are read much later: both are kept, the reuse's besides
    // the runs kept, by file identity however the path is spelled.
    func test_thisRunsAndTheReusedRunsFolders_areKept_however_theirPathsAreSpelled() throws {
        let resumed = try folder("resumed", at: 0)
        let reused = try folder("reused", at: 5)
        try folder("older", at: 10)
        try folder("newest", at: 20)
        let link = try makeTemporaryDirectory() + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)

        let pruning = LogFolderPruning.prune(
            root: root,
            current: [current, link + "/./resumed"],
            protected: [link + "/reused/"],
            keeping: 2
        )

        XCTAssertEqual(pruning.removed.map(\.folders), [["older"]])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "newest", "resumed", "reused"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: resumed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reused))
    }

    // A run still writing its results file, or still going, holding its marker, is left and said. A holder's record
    // left by a run that has ended protects nothing.
    func test_aRunStillGoing_isLeft_andAStaleHoldersRecordProtectsNothing() throws {
        let writing = try folder("writing", at: 0)
        let going = try folder("going", at: 1, results: false)
        let stale = try folder("stale", at: 2)
        try write("123 Nov 3 host", to: stale + "/.results.jsonl.holder")
        try setDates(of: stale, to: 2)
        try folder("newest", at: 10)
        let file = try ResultsFile.Opener().openForResume(at: writing + "/results.jsonl")
        let marker = try XCTUnwrap(RunMarker.hold(in: going))
        // Recording the holder wrote to the folder, as a run would, which only dating it again undoes.
        try setDates(of: writing, to: 0)
        try setDates(of: going, to: 1)
        // Pruned once the runs before it are kept: the log-only "going" is older than the oldest run kept.
        try folder("newer", at: 11)

        let pruning = prune(keeping: 3)

        XCTAssertEqual(pruning.removed.map(\.folders), [["stale"]])
        XCTAssertEqual(pruning.left, [
            .init(folders: ["writing"], reason: .inUse),
            .init(folders: ["going"], reason: .inUse),
        ])
        file.close()
        marker.release()
        try setDates(of: writing, to: 0)
        XCTAssertEqual(prune(keeping: 3).removed.map(\.folders), [["writing"], ["going"]])
    }

    // A run reusing an earlier run's results copies its logs much later, and holds shared locks on its folders until
    // then: a run that prunes in another lock domain, as a test plan's run may, leaves them.
    func test_aRunThatAReuseReads_isLeftInUse() throws {
        let reused = try folder("reused", at: 0)
        try folder("newest", at: 10)
        let reading = ReusedFolders(holding: [reused], resultsFile: reused + "/results.jsonl")

        XCTAssertEqual(prune(keeping: 2).left, [.init(folders: ["reused"], reason: .inUse)])
        withExtendedLifetime(reading) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: reused))
    }

    // A lock that can't be checked, as where flock isn't supported, or a marker that can't be opened, says nothing of
    // whether another run holds it: the folder is left, and said so, not said to be in use.
    func test_aFolderWhoseLockCantBeChecked_isLeft_notSaidToBeInUse() throws {
        try XCTSkipIf(geteuid() == 0, "root opens any file")
        let unreadable = try folder("unreadable", at: 0)
        try folder("newest", at: 10)
        XCTAssertEqual(chmod(unreadable + "/" + RunMarker.fileName, 0o000), 0)

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed, [])
        XCTAssertEqual(
            pruning.left,
            [.init(folders: ["unreadable"], reason: .couldNotCheck(String(cString: strerror(EACCES))))]
        )
    }

    // A folder an older SwiftMutator made has no marker, so one whose `running/` was written to in the last day may
    // still be testing.
    func test_anUnmarkedFolderWithOutputWrittenLately_isLeftInUse() throws {
        let unmarked = try folder("unmarked", at: 0, marker: false)
        try write("output", to: unmarked + "/running/1_a.log")
        try setDates(of: unmarked, to: 0)
        try folder("newest", at: 10)
        let then = start.addingTimeInterval(0)

        let soon = prune(keeping: 2, now: then.addingTimeInterval(60 * 60))
        XCTAssertEqual(soon.left, [.init(folders: ["unmarked"], reason: .inUse)])

        let later = prune(keeping: 2, now: then.addingTimeInterval(25 * 60 * 60))
        XCTAssertEqual(later.removed.map(\.folders), [["unmarked"]])
    }

    // A folder that holds a file SwiftMutator doesn't write, or a folder in `running/`, is left and said.
    func test_aFolderHoldingFilesSwiftMutatorDidntWrite_isLeft() throws {
        let notes = try folder("notes", at: 0)
        try write("mine", to: notes + "/notes.txt")
        try setDates(of: notes, to: 0)
        let nested = try folder("nested", at: 1)
        try FileManager.default.createDirectory(atPath: nested + "/running/sub", withIntermediateDirectories: true)
        try setDates(of: nested, to: 1)
        try folder("newest", at: 10)

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed, [])
        XCTAssertEqual(pruning.left, [
            .init(folders: ["notes"], reason: .foreignFiles(["notes.txt"])),
            .init(folders: ["nested"], reason: .foreignFiles(["running/sub"])),
        ])
        XCTAssertEqual(remaining(), ["Nov 3, 2026 at 9:00 AM", "nested", "newest", "notes"])
    }

    // Everything SwiftMutator writes in a log folder can go: logs, results files and their holders' records, a note,
    // the summary, the marker, and `running/` with its files.
    func test_everyFileSwiftMutatorWrites_canGo() throws {
        let full = try folder("full", at: 0)
        let names = [
            ".results.jsonl.holder", ".results.jsonl.holder.4242", "summary.json", ".DS_Store", "running/1_a.log",
            "running/baseline run",
        ]
        for name in names {
            try write("x", to: full + "/" + name)
        }
        try setDates(of: full, to: 0)
        try folder("newest", at: 10)

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["full"]])
        XCTAssertEqual(pruning.left, [])
    }

    // Only SwiftMutator's folders are touched: one with a marker, or one whose results file's header names it. Empty
    // folders, which another run may have just claimed, links, plain files and a folder whose results file names
    // another folder are left, and not said.
    func test_onlySwiftMutatorsFolders_areTouched() throws {
        try FileManager.default.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
        try setDates(of: root + "/empty", to: -50)
        let elsewhere = try makeTemporaryDirectory()
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: elsewhere)
        try write("x", to: root + "/.DS_Store")
        try folder("someone's", at: -40, marker: false, results: false)
        try folder("names another", at: -30, marker: false, header: elsewhere)
        try folder("older version", at: -20, marker: false)
        try folder("kept", at: 10)

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed.map(\.folders), [["older version"]])
        XCTAssertEqual(pruning.left, [])
        XCTAssertEqual(
            remaining(),
            [".DS_Store", "Nov 3, 2026 at 9:00 AM", "empty", "kept", "link", "names another", "someone's"]
        )
    }

    // A folder with several runs' results files, as a folder held before each run got one of its own, is one.
    func test_aFolderWithSeveralResultsFiles_isOne() throws {
        let shared = try folder("shared", at: 0)
        try write(header(naming: shared), to: shared + "/results-2.jsonl")
        try setDates(of: shared, to: 0)
        try folder("newest", at: 10)

        XCTAssertEqual(prune(keeping: 2).removed.map(\.folders), [["shared"]])
    }

    // A removed shard says which it was, as `keepLogFolders` below the number of shards merged loses shards.
    func test_aRemovedShard_saysWhichItWas() throws {
        try folder("shard", at: 0, shard: 2)
        try folder("newest", at: 10)

        XCTAssertEqual(prune(keeping: 2).removed, [.init(folders: ["shard"], shard: Shard(index: 2, count: 4))])
    }

    // A folder that can't be removed is said, not thrown; one that has gone is as good as removed.
    func test_aFolderThatCantBeRemoved_isSaid_andOneThatHasGone_isRemoved() throws {
        let locked = try folder("locked", at: 0)
        try folder("newest", at: 10)
        XCTAssertEqual(chmod(locked, 0o555), 0)
        addTeardownBlock { _ = chmod(locked, 0o755) }

        let pruning = prune(keeping: 2)

        XCTAssertEqual(pruning.removed, [])
        XCTAssertEqual(pruning.left.map(\.folders), [["locked"]])
        guard case let .couldNotRemove(reason) = pruning.left.first?.reason else {
            return XCTFail("\(pruning.left)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(LogFolderPruning.removeFolder(atPath: root + "/gone"))
    }

    // MARK: - Helpers

    private func prune(keeping: Int, now: Date = Date()) -> LogFolderPruning {
        LogFolderPruning.prune(root: root, current: [current], protected: [], keeping: keeping, now: now)
    }

    /// What is left in the root, sorted.
    private func remaining() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
    }

    /// Makes the log folder `name` in the root, dated `minutes` after `start`, with a kept log, and, as asked, the
    /// run's marker, a results file whose header names `header` (the folder itself, by default), and a resumed
    /// session's note naming `note`.
    @discardableResult
    private func folder(
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
            try write(String(decoding: try resultsFileData([line]), as: UTF8.self), to: path + "/results.jsonl")
        }
        if let note {
            try write(ResultsFile.note(pointingTo: note, session: 2), to: path + "/" + ResultsFile.noteFileName)
        }
        try setDates(of: path, to: minutes)
        return path
    }

    /// A results file's header line naming `logDirectory`.
    private func header(naming logDirectory: String, mutant: String? = nil, shard: Int? = nil) throws -> String {
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
        return String(decoding: try resultsFileData([line]), as: UTF8.self)
    }

    /// Dates `path`, and everything in it, `minutes` after `start`: their modification and creation dates.
    private func setDates(of path: String, to minutes: Double) throws {
        let date = start.addingTimeInterval(minutes * 60)
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: path)) ?? []
        // The folder last, as dating what is in it changes nothing, but writing would.
        for item in names.map({ path + "/" + $0 }) + [path] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item)
            try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: item)
        }
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
}
