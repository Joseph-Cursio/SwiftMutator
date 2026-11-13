@testable import muterCore
import XCTest

/// What the logger says of the earlier runs' log folders that `keepLogFolders` removed and left.
final class LoggerLogFolderPruningTests: MuterTestCase {
    private let sut = Logger()

    // Up to five runs by name, then how many more; a resumed run's folders on one line, and a shard said.
    func test_removedRuns_areNamed_fiveAtMost() {
        let removed = (1...7).map { LogFolderPruning.Removed(folders: ["Oct \($0), 2026 at 9:00 AM"], shard: nil) }
        var pruning = LogFolderPruning(root: "/code/SwiftProjectLint_muter_logs", keeping: 5)
        pruning.removed = [
            .init(folders: ["Sep 30, 2026 at 8:00 AM", "Sep 30, 2026 at 9:00 AM"], shard: nil),
            .init(folders: ["Sep 30, 2026 at 10:00 AM"], shard: Shard(index: 2, count: 4)),
        ] + removed
        pruning.freedBytes = 1_934_000_000

        sut.logFoldersPruned(pruning)

        XCTAssertEqual(printer.linesPassed, [
            """
            🧹 Removed the log folders of 9 earlier runs, 1.9 GB, from /code/SwiftProjectLint_muter_logs, keeping the \
            newest 5 runs (keepLogFolders: 5):
              Sep 30, 2026 at 8:00 AM, Sep 30, 2026 at 9:00 AM
              Sep 30, 2026 at 10:00 AM (shard 2 of 4)
              Oct 1, 2026 at 9:00 AM
              Oct 2, 2026 at 9:00 AM
              Oct 3, 2026 at 9:00 AM
              … and 4 more
            """,
        ])
    }

    // Each run left, and why, after the runs removed.
    func test_eachRunLeft_saysWhy() {
        var pruning = LogFolderPruning(root: "/p_muter_logs", keeping: 2)
        pruning.removed = [.init(folders: ["Oct 9, 2026 at 9:00 AM"], shard: nil)]
        pruning.freedBytes = 512
        let files = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt", "g.txt"]
        pruning.left = [
            .init(folders: ["Oct 1, 2026 at 8:12 AM"], reason: .inUse),
            .init(folders: ["Sep 30, 2026 at 4:02 PM"], reason: .foreignFiles(["notes.txt"])),
            .init(folders: ["Sep 29, 2026 at 4:02 PM"], reason: .foreignFiles(files)),
            .init(folders: ["Sep 29, 2026 at 1:00 PM"], reason: .couldNotRemove("permission denied")),
        ]

        sut.logFoldersPruned(pruning)

        XCTAssertEqual(printer.linesPassed, [
            """
            🧹 Removed the log folders of 1 earlier run, 512 bytes, from /p_muter_logs, keeping the newest 2 runs \
            (keepLogFolders: 2):
              Oct 9, 2026 at 9:00 AM
            ⚠️ Left Oct 1, 2026 at 8:12 AM: another SwiftMutator run is using it.
            ⚠️ Left Sep 30, 2026 at 4:02 PM: it holds files SwiftMutator didn't write: notes.txt
            ⚠️ Left Sep 29, 2026 at 4:02 PM: it holds files SwiftMutator didn't write: a.txt, b.txt, c.txt, d.txt, \
            e.txt and 2 more
            ⚠️ Couldn't remove Sep 29, 2026 at 1:00 PM: permission denied
            """,
        ])
    }

    // With none removed, a line first says where the runs left are, and what would have removed them, so a warning
    // that comes back run after run says what it is about. A lock that couldn't be checked is said as such.
    func test_runsLeft_withNoneRemoved_followALineSayingWhere() {
        var pruning = LogFolderPruning(root: "/p_muter_logs", keeping: 5)
        pruning.left = [
            .init(folders: ["Sep 30, 2026 at 4:02 PM"], reason: .foreignFiles(["notes.txt"])),
            .init(folders: ["Sep 29, 2026 at 1:00 PM"], reason: .couldNotCheck("Operation not supported")),
        ]

        sut.logFoldersPruned(pruning)

        XCTAssertEqual(printer.linesPassed, [
            """
            🧹 Left the log folders of 2 earlier runs in /p_muter_logs, beyond the newest 5 runs (keepLogFolders: 5):
            ⚠️ Left Sep 30, 2026 at 4:02 PM: it holds files SwiftMutator didn't write: notes.txt
            ⚠️ Left Sep 29, 2026 at 1:00 PM: couldn't tell whether another SwiftMutator run is using it: Operation \
            not supported
            """,
        ])
    }

    func test_nothingToSay_printsNothing() {
        sut.logFoldersPruned(LogFolderPruning(root: "/p_muter_logs", keeping: 2))

        XCTAssertEqual(printer.linesPassed, [])
    }

    func test_sizes_areInDecimalUnits() {
        XCTAssertEqual(Logger.size(0), "0 bytes")
        XCTAssertEqual(Logger.size(1), "1 byte")
        XCTAssertEqual(Logger.size(999), "999 bytes")
        XCTAssertEqual(Logger.size(1_000), "1.0 KB")
        XCTAssertEqual(Logger.size(960_400), "960.4 KB")
        XCTAssertEqual(Logger.size(999_960), "1.0 MB")
        XCTAssertEqual(Logger.size(1_934_000_000), "1.9 GB")
    }
}
