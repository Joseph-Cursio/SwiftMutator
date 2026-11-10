@testable import muterCore
import XCTest

extension WorkerSimulatorsTests {
    func test_removeAll_deletesEachSimulatorMadeOnce_andKeepsGoingPastAFailure() async throws {
        simctl.answering { arguments in
            switch arguments.first {
            case "clone": .init(output: "DDDDDDDD-0000-0000-0000-00000000000\(arguments[2].suffix(1))\n")
            case "delete" where arguments.last?.hasSuffix("0") == true: .init(status: 1, errors: "busy")
            default: nil
            }
        }
        let simulators = makeSimulators()
        let made = try await simulators.prepare(2, like: "id=\(iPhone17Pro)", for: mutatedProject)
        let commandsBefore = simctl.commands.count

        await simulators.removeAll()

        let deletes = Array(simctl.commands.dropFirst(commandsBefore))
        XCTAssertEqual(Set(deletes), Set(made.map { ["delete", $0.udid] }))
        XCTAssertEqual(deletes.count, 2, "each once, the failed one included")
        XCTAssertEqual(simulators.recorded, [made[0].udid], "the one that failed, for a later call")

        // A later call tries the failed one once more, and only it, however often it fails.
        await simulators.removeAll()

        XCTAssertEqual(Array(simctl.commands.dropFirst(commandsBefore + 2)), [["delete", made[0].udid]])
        XCTAssertEqual(simulators.recorded, [made[0].udid])
    }

    // A stop while the work runs kills this process's children every 0.25 s, a delete under way among them. The
    // `afterWorkEnds` hook's `removeAll()`, once the work has ended, must still find the simulator to delete.
    func test_aSimulatorWhoseDeleteIsKilled_isDeletedByTheNextRemoveAll() async throws {
        simctl.answering { arguments in
            switch arguments.first {
            case "clone": .init(output: "DDDDDDDD-0000-0000-0000-00000000000\(arguments[2].suffix(1))\n")
            case "delete": .init(status: SIGKILL, endedBySignal: true)
            default: nil
            }
        }
        let simulators = makeSimulators()
        let made = try await simulators.prepare(2, like: "id=\(iPhone17Pro)", for: mutatedProject)
        await simulators.removeAll()
        XCTAssertEqual(simulators.recorded, made.map(\.udid))
        simctl.answering { _ in nil }
        let commandsBefore = simctl.commands.count

        await simulators.removeAll()

        XCTAssertEqual(Set(simctl.commands.dropFirst(commandsBefore)), Set(made.map { ["delete", $0.udid] }))
        XCTAssertEqual(simulators.recorded, [])
    }

    func test_aFailureToMakeOne_keepsThoseWhoseDeleteIsKilled_forRemoveAll() async throws {
        simctl.answering { arguments in
            switch arguments.first {
            case "clone" where arguments[2].hasSuffix("w2"): .init(status: 1, errors: "no room")
            case "clone": .init(output: "CCCCCCCC-0000-0000-0000-00000000000\(arguments[2].suffix(1))\n")
            case "delete" where arguments.last?.hasSuffix("1") == true: .init(status: SIGKILL, endedBySignal: true)
            default: nil
            }
        }
        let simulators = makeSimulators()

        _ = await failingToPrepare(3, like: "id=\(iPhone17Pro)", with: simulators)

        XCTAssertEqual(simulators.recorded, ["CCCCCCCC-0000-0000-0000-000000000001"])
    }

    func test_removeAll_withNothingMade_startsNoProcess() async {
        await makeSimulators().removeAll()

        XCTAssertEqual(simctl.commands, [])
    }
}
