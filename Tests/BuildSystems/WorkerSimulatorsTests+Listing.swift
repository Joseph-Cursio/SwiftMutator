@testable import muterCore
import XCTest

/// Whether simctl lists the simulator a destination names by its `id=` or `name=` alone, which decides whether an
/// xcodebuild run on it can stop at its first failed test.
extension WorkerSimulatorsTests {
    func test_aDestinationNamingAListedSimulator_isListed() async {
        let simulators = makeSimulators()

        for udid in [iPhone17Pro, bootedTwin] {
            let listed = await simulators.listsASimulator(namedBy: "id=\(udid)")
            XCTAssertTrue(listed, udid)
        }
        XCTAssertEqual(simctl.commands, Array(repeating: ["list", "devices", "--json"], count: 2))
    }

    // A device's UDID, or a name no simulator has, names none simctl lists.
    func test_aDestinationNamingNoListedSimulator_isntListed() async {
        let simulators = makeSimulators()

        for destination in ["id=00008120-001A2B3C4D5E601E", "name=iPhone 3G"] {
            let listed = await simulators.listsASimulator(namedBy: destination)
            XCTAssertFalse(listed, destination)
        }
    }

    // Nothing to list for a Mac.
    func test_aDestinationThatIsntASimulatorsShape_isntListed_withoutAskingSimctl() async {
        let listed = await makeSimulators().listsASimulator(namedBy: "platform=macOS")

        XCTAssertFalse(listed)
        XCTAssertEqual(simctl.commands, [])
    }

    // A list simctl fails to print, or prints unreadably, lists nothing.
    func test_aListThatFails_orCantBeRead_listsNothing() async {
        for list in [nil, Data("not JSON".utf8)] {
            simctl = SimctlStandIn(list: list)

            let listed = await makeSimulators().listsASimulator(namedBy: "id=\(iPhone17Pro)")

            XCTAssertFalse(listed)
            XCTAssertEqual(simctl.commands, [["list", "devices", "--json"]])
        }
    }
}
