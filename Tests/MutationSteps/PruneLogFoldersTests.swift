import Foundation
@testable import muterCore
import XCTest

/// The step that prunes earlier runs' log folders (`keepLogFolders:`), with a pruner that touches no disk.
final class PruneLogFoldersTests: MuterTestCase {
    /// One call to the pruner: the logs root, this run's folders, the folders it must keep, and how many to keep.
    private struct Call {
        let root: String
        let current: [String]
        let protected: [String]
        let keeping: Int
    }

    private let state = MutationTestState()
    private let calls = Locked<[Call]>([])
    private var result = LogFolderPruning(root: "/project_muter_logs", keeping: 3)
    private var sent: [LogFolderPruning] = []
    private var subscription: RunEvents.Subscription?

    override func setUp() {
        super.setUp()
        state.loggingDirectory = "/project_muter_logs/Nov 3, 2026 at 9:00 AM"
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", keepLogFolders: 3)
        subscription = runEvents.observe(.logFoldersPruned) { [weak self] event in
            (event.object as? LogFolderPruning).map { self?.sent.append($0) }
        }
    }

    private var sut: PruneLogFolders {
        let callLog = calls
        let pruned = result
        return PruneLogFolders { root, current, protected, keeping in
            callLog.change { $0.append(Call(root: root, current: current, protected: protected, keeping: keeping)) }
            return pruned
        }
    }

    // Unset, the default, removes nothing, and so does a state with no log folder.
    func test_withoutTheKey_orWithoutALogFolder_nothingIsPruned() throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift")
        let unset = try sut.run(with: state)

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", keepLogFolders: 3)
        state.loggingDirectory = ""
        let withoutAFolder = try sut.run(with: state)

        XCTAssertEqual(unset, [])
        XCTAssertEqual(withoutAFolder, [])

        XCTAssertTrue(calls.value.isEmpty)
        XCTAssertEqual(sent, [])
    }

    // The logs' root is the folder the run's own is in, and that one is this run's.
    func test_prunesTheLogsRoot_keepingThisRun() throws {
        _ = try sut.run(with: state)

        XCTAssertEqual(calls.value.count, 1)
        XCTAssertEqual(calls.value.first?.root, "/project_muter_logs")
        XCTAssertEqual(calls.value.first?.current, ["/project_muter_logs/Nov 3, 2026 at 9:00 AM"])
        XCTAssertEqual(calls.value.first?.protected, [])
        XCTAssertEqual(calls.value.first?.keeping, 3)
    }

    // Nothing beyond the runs kept is no news.
    func test_theEvent_isSentOnlyWhenSomethingWasRemovedOrLeft() throws {
        _ = try sut.run(with: state)
        XCTAssertEqual(sent, [])

        result.removed = [.init(folders: ["Oct 9, 2026 at 9:00 AM"], shard: nil)]
        _ = try sut.run(with: state)
        result.removed = []
        result.left = [.init(folders: ["Oct 1, 2026 at 8:12 AM"], reason: .inUse)]
        _ = try sut.run(with: state)

        XCTAssertEqual(sent.map(\.removed.count), [1, 0])
        XCTAssertEqual(sent.map(\.left.count), [0, 1])
    }

    // A resumed run's earlier sessions are this run: the first session's folder, which holds the results file, and
    // every session's own.
    func test_aResume_keepsItsEarlierSessionsFolders_asThisRun() throws {
        state.resumeState = try ResumeState.make(
            path: "/project_muter_logs/first/results.jsonl",
            lines: [
                ResultsHeader.make(logDirectory: "/project_muter_logs/first"),
                ResultsHeader.make(session: 2, logDirectory: "/project_muter_logs/second"),
            ],
            file: ResultsFilesSpy.File(path: "/project_muter_logs/first/results.jsonl", failFromLine: nil)
        )

        _ = try sut.run(with: state)

        XCTAssertEqual(calls.value.first?.current, [
            "/project_muter_logs/Nov 3, 2026 at 9:00 AM",
            "/project_muter_logs/first",
            "/project_muter_logs/first",
            "/project_muter_logs/second",
        ])
        XCTAssertEqual(calls.value.first?.protected, [])
    }

    // The run a reuse reads is copied from much later, holding no lock: its folders are kept besides the runs kept.
    func test_aReuse_protectsTheReusedRunsFolders() throws {
        state.resumeState = try ResumeState.make(
            path: "/elsewhere_muter_logs/first/results.jsonl",
            lines: [ResultsHeader.make(logDirectory: "/elsewhere_muter_logs/first")],
            file: nil
        )

        _ = try sut.run(with: state)

        XCTAssertEqual(calls.value.first?.current, ["/project_muter_logs/Nov 3, 2026 at 9:00 AM"])
        XCTAssertEqual(calls.value.first?.protected, ["/elsewhere_muter_logs/first", "/elsewhere_muter_logs/first"])
    }
}
