import Foundation
@testable import muterCore
import XCTest

extension LogFolderPruningTests {
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
}
