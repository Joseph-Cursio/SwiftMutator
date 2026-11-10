@testable import muterCore
import XCTest

extension WorkerSimulatorsTests {
    func test_theSweep_deletesThisProjectsSimulators_whateverTheirOwner_andOthersOnlyWhenTheirOwnerHasEnded() async {
        let live = RecordedProcess(id: 77, started: 5)
        let dead = RecordedProcess(id: 78, started: 6)
        let otherProject = "cf60c83c" // /tmp/Other_mutated
        simctl = SimctlStandIn(list: list(of: [
            ("swiftmutator-\(projectHash)-\(live.id)-\(live.started)-w0", "11111111-0000-0000-0000-000000000000"),
            ("swiftmutator-\(projectHash)-\(dead.id)-\(dead.started)-w1", "22222222-0000-0000-0000-000000000000"),
            ("swiftmutator-\(otherProject)-\(live.id)-\(live.started)-w0", "33333333-0000-0000-0000-000000000000"),
            ("swiftmutator-\(otherProject)-\(dead.id)-\(dead.started)-w0", "44444444-0000-0000-0000-000000000000"),
            ("swiftmutator-probe-twin", "55555555-0000-0000-0000-000000000000"),
            ("XMR-78-0123abcd-0", "66666666-0000-0000-0000-000000000000"),
            ("iPhone 17 Pro", "77777777-0000-0000-0000-000000000000"),
        ]))

        await makeSimulators(running: [live]).sweep(mutatedProject)

        XCTAssertEqual(simctl.commands.first, ["list", "devices", "--json"])
        XCTAssertEqual(Set(simctl.commands.dropFirst()), [
            ["delete", "11111111-0000-0000-0000-000000000000"],
            ["delete", "22222222-0000-0000-0000-000000000000"],
            ["delete", "44444444-0000-0000-0000-000000000000"],
        ])
        XCTAssertEqual(simctl.commands.count, 4)
    }

    // A simulator this run made and couldn't delete yet is still its own, whose `removeAll()` deletes it.
    func test_theSweep_skipsTheSimulatorsThisRunStillRecords() async throws {
        let dead = RecordedProcess(id: 78, started: 6)
        let mine = "EEEEEEEE-0000-0000-0000-000000000000"
        let theirs = "FFFFFFFF-0000-0000-0000-000000000000"
        let base = "88888888-0000-0000-0000-000000000000"
        simctl = SimctlStandIn(list: list(of: [
            ("iPhone 17", base),
            ("swiftmutator-\(projectHash)-\(owner.id)-\(owner.started)-w0", mine),
            ("swiftmutator-\(projectHash)-\(dead.id)-\(dead.started)-w0", theirs),
        ]))
        simctl.answering { arguments in
            switch arguments.first {
            case "clone": .init(output: "\(mine)\n")
            case "delete" where arguments.last == mine: .init(status: 1, errors: "busy")
            default: nil
            }
        }
        let simulators = makeSimulators()
        _ = try await simulators.prepare(1, like: "id=\(base)", for: mutatedProject)
        await simulators.removeAll()
        let commandsBefore = simctl.commands.count

        await simulators.sweep(mutatedProject)

        XCTAssertEqual(
            Array(simctl.commands.dropFirst(commandsBefore)),
            [["list", "devices", "--json"], ["delete", theirs]]
        )
    }

    func test_theSweep_ofTheFixture_deletesNothing() async {
        await makeSimulators().sweep(mutatedProject)

        XCTAssertEqual(simctl.commands, [["list", "devices", "--json"]])
    }

    func test_theSweep_withNoList_deletesNothing() async {
        simctl = SimctlStandIn(list: nil)

        await makeSimulators().sweep(mutatedProject)

        XCTAssertEqual(simctl.commands, [["list", "devices", "--json"]])
    }
}
