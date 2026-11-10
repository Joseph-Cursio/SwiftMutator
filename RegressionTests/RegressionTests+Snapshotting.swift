@testable import muterCore
import SnapshotTesting
import TestingExtensions
import XCTest

extension RegressionTests {
    /// Keys left out of the snapshots: where and how long a run and each mutant took, the run's details (its log
    /// folder, build, toolchain and settings), and the killing tests, their summary and the kills only suspect tests
    /// made, which depend on timing (runs stop at their first failed test). Each is dropped at any depth, inside arrays
    /// too (`recursivelyFiltered`), so the snapshots, which hold none of them, need no re-recording.
    static let keysToExclude: Set<String> = [
        "filePath", "utf8Offset", "timeElapsed", "durationSeconds", "run",
        "killingTests",
        "killingTestSummary",
        "killedOnlyBySuspectTests",
    ]

    /// How a report is compared with its snapshot: as JSON, without `keysToExclude`.
    static var snapshotting: Snapshotting<MuterTestReport, String> {
        .json { keysToExclude.contains($0) }
    }
}
