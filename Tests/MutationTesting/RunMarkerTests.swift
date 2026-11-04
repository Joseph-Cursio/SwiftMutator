import Foundation
@testable import muterCore
import XCTest

/// The marker a run holds a lock on in its log folder, so no other run prunes the folder while it goes.
final class RunMarkerTests: MuterTestCase {
    // The lock is held from the moment the marker is made until it is released, and a run that prunes sees it.
    func test_hold_makesTheMarker_andHoldsItsLockUntilReleased() throws {
        let folder = try makeTemporaryDirectory()

        let marker = try XCTUnwrap(RunMarker.hold(in: folder))

        XCTAssertEqual(marker.path, folder + "/" + RunMarker.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(ResultsFile.probeLock(marker.path), .inUse)
        XCTAssertNil(RunMarker.hold(in: folder), "a second holder")
        marker.release()
        guard case let .held(probe) = ResultsFile.probeLock(marker.path) else {
            return XCTFail("\(ResultsFile.probeLock(marker.path))")
        }
        close(probe)
        // The file stays, and marks the folder as SwiftMutator's.
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    // However the marker goes, its lock goes with it, as when the process exits.
    func test_aMarkerThatGoes_releasesItsLock() throws {
        let folder = try makeTemporaryDirectory()
        var marker = RunMarker.hold(in: folder)
        XCTAssertNotNil(marker)

        marker = nil

        guard case let .held(probe) = ResultsFile.probeLock(folder + "/" + RunMarker.fileName) else {
            return XCTFail("still locked")
        }
        close(probe)
        withExtendedLifetime(marker) {}
    }

    // A folder that isn't there gets none, which stops nothing.
    func test_hold_inAFolderThatIsntThere_givesNone() throws {
        XCTAssertNil(RunMarker.hold(in: try makeTemporaryDirectory() + "/missing"))
    }

    // A link in the marker's place is never followed.
    func test_hold_neverFollowsALinkInItsPlace() throws {
        let folder = try makeTemporaryDirectory()
        let target = try makeTemporaryDirectory() + "/target"
        try FileManager.default.createSymbolicLink(
            atPath: folder + "/" + RunMarker.fileName,
            withDestinationPath: target
        )

        XCTAssertNil(RunMarker.hold(in: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    // A probe tells a lock another process holds from one it can't check, which says nothing of whether a run uses the
    // file, and from a file that isn't there.
    func test_probeLock_tellsInUseFromMissingAndFromFailure() throws {
        let folder = try makeTemporaryDirectory()
        let marker = try XCTUnwrap(RunMarker.hold(in: folder))

        XCTAssertEqual(ResultsFile.probeLock(marker.path), .inUse)
        XCTAssertEqual(ResultsFile.probeLock(folder + "/missing"), .missing)
        XCTAssertEqual(ResultsFile.probeLock(folder), .failed(EISDIR))
        marker.release()
    }

    // A file this user can only read is still probed, opened to read.
    func test_probeLock_ofAFileThatCanOnlyBeRead_locksIt() throws {
        let folder = try makeTemporaryDirectory()
        let path = folder + "/results.jsonl"
        XCTAssertTrue(
            FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o444])
        )
        guard case let .held(probe) = ResultsFile.probeLock(path) else {
            return XCTFail("\(ResultsFile.probeLock(path))")
        }
        close(probe)
    }

    // A reuse's shared locks on the earlier run's folders show them in use to a run that prunes, as long as they are
    // held: the marker of each folder that has one, and the results file of its own folder when it has none.
    func test_reusedFolders_holdTheirMarkersOrResultsFile_untilTheyGo() throws {
        let marked = try makeTemporaryDirectory()
        let unmarked = try makeTemporaryDirectory()
        RunMarker.hold(in: marked)?.release()
        let results = unmarked + "/results.jsonl"
        XCTAssertTrue(FileManager.default.createFile(atPath: results, contents: Data()))
        var reused: ReusedFolders? = ReusedFolders(holding: [unmarked, marked], resultsFile: results)

        XCTAssertEqual(ResultsFile.probeLock(marked + "/" + RunMarker.fileName), .inUse)
        XCTAssertEqual(ResultsFile.probeLock(results), .inUse)
        XCTAssertNotNil(ReusedFolders(holding: [marked], resultsFile: results), "another reuse")

        reused = nil
        for path in [marked + "/" + RunMarker.fileName, results] {
            guard case let .held(probe) = ResultsFile.probeLock(path) else { return XCTFail(path) }
            close(probe)
        }
        withExtendedLifetime(reused) {}
    }
}
