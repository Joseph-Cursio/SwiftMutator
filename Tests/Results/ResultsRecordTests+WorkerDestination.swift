@testable import muterCore
import XCTest

extension ResultsRecordTests {
    // Sorted right after `workers`, which it says more about.
    func test_whereTheWorkersTested_roundTrips_rightAfterWorkers() throws {
        for (destination, value) in [
            (ResultsHeader.WorkerDestination.ownSimulators, "true"),
            (.testCommandsDestination, "false"),
        ] {
            var header = makeHeader()
            header.workersOnOwnSimulators = destination

            let written = try line(header)

            XCTAssertTrue(
                written.contains(#""workers":4,"workersOnOwnSimulators":\#(value)"#),
                "\(destination) in \(written)"
            )
            XCTAssertEqual(try decode(ResultsHeader.self, from: written), header)
        }
    }

    // A header an earlier SwiftMutator wrote has no key, and is in the same format.
    func test_aHeaderWithoutWhereTheWorkersTested_readsAsNotRecorded() throws {
        let header = makeHeader()
        let written = try line(header)

        XCTAssertFalse(written.contains("workersOnOwnSimulators"), written)
        XCTAssertEqual(try decode(ResultsHeader.self, from: written).workersOnOwnSimulators, .notRecorded)
        XCTAssertEqual(try decode(ResultsHeader.self, from: written), header)
        XCTAssertEqual(header.formatVersion, ResultsCoding.formatVersion)
    }
}
