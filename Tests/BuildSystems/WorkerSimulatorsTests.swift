@testable import muterCore
import XCTest

/// `WorkerSimulators` with a stand-in for `xcrun simctl`, which answers `list devices --json` with the fixture
/// `SimulatorDestinationTests` reads, or a list a test gives, and records every command. No simulator is touched.
final class WorkerSimulatorsTests: MuterTestCase {
    let iPhone17Pro = "693E96A4-A11F-4223-B131-CFC50C9A17B8" // Shutdown, iOS 26.5
    let bootedTwin = "461B8A08-7CE1-43BD-8F86-1812452225FB" // Booted, an iPhone 17 on iOS 26.5
    let mutatedProject = URL(fileURLWithPath: "/tmp/App_mutated")
    /// The first 8 hex digits of the SHA-256 of `/tmp/App_mutated`.
    let projectHash = "fd200ba3"
    let owner = RecordedProcess(id: 4_242, started: 1_700_000_000_123_456)
    var simctl = SimctlStandIn(list: nil)

    override func setUp() {
        super.setUp()
        simctl = SimctlStandIn(list: fixture)
    }

    // MARK: - Names

    func test_aName_saysWhoseItIs_andReadsBack() throws {
        let name = WorkerSimulatorName(projectHash: projectHash, owner: owner, worker: 3)

        XCTAssertEqual(name.text, "swiftmutator-fd200ba3-4242-1700000000123456-w3")
        XCTAssertEqual(WorkerSimulatorName(name.text), name)
    }

    func test_theProjectHash_isOfTheStandardizedPath() {
        XCTAssertEqual(WorkerSimulatorName.projectHash(of: mutatedProject), projectHash)
        XCTAssertEqual(
            WorkerSimulatorName.projectHash(of: URL(fileURLWithPath: "/tmp/sub/../App_mutated")),
            projectHash
        )
        XCTAssertNotEqual(
            WorkerSimulatorName.projectHash(of: URL(fileURLWithPath: "/tmp/Other_mutated")),
            projectHash
        )
    }

    func test_noOtherNameIsAWorkersSimulator() {
        for name in [
            "swiftmutator-probe-x",
            "swiftmutator-probe-twin",
            "XMR-4242-0123abcd-0",
            "iPhone 17 Pro",
            "swiftmutator-fd200ba3-4242-1700000000123456-wX",
            "swiftmutator-fd200ba3-4242-1700000000123456-w",
            "swiftmutator-fd200ba3-4242-1700000000123456-3",
            "swiftmutator-FD200BA3-4242-1700000000123456-w3",
            "swiftmutator-fd200ba-4242-1700000000123456-w3",
            "swiftmutator-fd200ba3-+4242-1700000000123456-w3",
            "swiftmutator-fd200ba3-4242-1700000000123456-w3-x",
            "swiftmutator-fd200ba3-4242--w3",
            "my swiftmutator-fd200ba3-4242-1700000000123456-w3",
        ] {
            XCTAssertNil(WorkerSimulatorName(name), name)
        }
    }

    // MARK: - Making them

    func test_aShutDownSimulator_isCloned_once_perWorker() async throws {
        simctl.answering { arguments in
            guard arguments.first == "clone" else { return nil }
            return .init(output: "AAAAAAAA-0000-0000-0000-00000000000\(arguments[2].suffix(1))\n")
        }
        let simulators = makeSimulators()

        let made = try await simulators.prepare(
            2,
            like: "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            for: mutatedProject
        )

        let names = ["w0", "w1"].map { "swiftmutator-fd200ba3-4242-1700000000123456-\($0)" }
        XCTAssertEqual(simctl.commands, [
            ["list", "devices", "--json"],
            ["clone", iPhone17Pro, names[0]],
            ["clone", iPhone17Pro, names[1]],
        ])
        XCTAssertEqual(made, [
            WorkerSimulator(
                udid: "AAAAAAAA-0000-0000-0000-000000000000",
                name: names[0],
                destination: "platform=iOS Simulator,id=AAAAAAAA-0000-0000-0000-000000000000"
            ),
            WorkerSimulator(
                udid: "AAAAAAAA-0000-0000-0000-000000000001",
                name: names[1],
                destination: "platform=iOS Simulator,id=AAAAAAAA-0000-0000-0000-000000000001"
            ),
        ])
        XCTAssertEqual(simulators.recorded, made.map(\.udid))
        XCTAssertEqual(simctl.timeLimits, [60, 60, 60])
    }

    // `simctl clone` refuses a booted simulator, and SwiftMutator never shuts the user's down.
    func test_aBootedSimulator_isMadeAnew_fromItsDeviceTypeAndRuntime_andNeverShutDown() async throws {
        simctl.answering { $0.first == "create" ? .init(output: "BBBBBBBB-0000-0000-0000-000000000000\n") : nil }

        let made = try await makeSimulators().prepare(1, like: "id=\(bootedTwin)", for: mutatedProject)

        XCTAssertEqual(simctl.commands.last, [
            "create",
            "swiftmutator-fd200ba3-4242-1700000000123456-w0",
            "com.apple.CoreSimulator.SimDeviceType.iPhone-17",
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        ])
        XCTAssertFalse(
            simctl.commands.contains { $0.first == "shutdown" || $0.first == "clone" },
            "\(simctl.commands)"
        )
        // An id alone names no platform, so the runtime's is used.
        XCTAssertEqual(made.map(\.destination), ["platform=iOS Simulator,id=BBBBBBBB-0000-0000-0000-000000000000"])
    }

    func test_aFailure_deletesTheSimulatorsMadeBeforeIt_andSaysWhy() async throws {
        simctl.answering { arguments in
            switch arguments.first {
            case "clone" where arguments[2].hasSuffix("w2"):
                .init(
                    status: 149,
                    errors: "An error was encountered processing the command "
                        + "(domain=com.apple.CoreSimulator.SimError, code=405):\n"
                        + "Unable to clone device in current state: Booted\n"
                )

            case "clone":
                .init(output: "CCCCCCCC-0000-0000-0000-00000000000\(arguments[2].suffix(1))\n")

            default:
                nil
            }
        }
        let simulators = makeSimulators()

        let error = await failingToPrepare(4, like: "id=\(iPhone17Pro)", with: simulators)

        XCTAssertEqual(
            error,
            "`xcrun simctl clone \(iPhone17Pro) swiftmutator-fd200ba3-4242-1700000000123456-w2` failed with exit code "
                + "149: Unable to clone device in current state: Booted"
        )
        XCTAssertEqual(
            Set(simctl.commands.filter { $0.first == "delete" }),
            [["delete", "CCCCCCCC-0000-0000-0000-000000000000"], ["delete", "CCCCCCCC-0000-0000-0000-000000000001"]]
        )
        XCTAssertFalse(simctl.commands.contains { $0.last?.hasSuffix("w3") == true }, "no simulator after the failure")
        XCTAssertEqual(simulators.recorded, [])
    }

    func test_aCloneThatPrintsNoUDID_orTimesOut_isAFailure() async {
        simctl.answering { $0.first == "clone" ? .init(output: "done\n") : nil }
        let printed = await failingToPrepare(1, like: "id=\(iPhone17Pro)")
        XCTAssertEqual(printed?.hasSuffix("` printed no UDID"), true, printed ?? "")

        simctl.answering { $0.first == "clone" ? .init(status: SIGKILL, endedBySignal: true, timedOut: true) : nil }
        let timedOut = await failingToPrepare(1, like: "id=\(iPhone17Pro)")
        XCTAssertEqual(timedOut?.hasSuffix("` didn't finish within 60 seconds"), true, timedOut ?? "")
    }

    func test_aDestinationThatNamesNoSimulator_orNoneThatIsListed_makesNone() async {
        let mac = await failingToPrepare(2, like: "platform=macOS")
        XCTAssertEqual(mac, "`-destination platform=macOS` names no simulator")
        XCTAssertEqual(simctl.commands, [], "nothing to list")

        let unlisted = await failingToPrepare(2, like: "platform=iOS Simulator,name=iPhone 3G")
        XCTAssertEqual(
            unlisted,
            "no available simulator matches `-destination platform=iOS Simulator,name=iPhone 3G`, or more than one does"
        )

        simctl = SimctlStandIn(list: Data("not JSON".utf8))
        let unreadable = await failingToPrepare(2, like: "id=\(iPhone17Pro)")
        XCTAssertEqual(unreadable, "SwiftMutator couldn't read simctl's list of simulators")
        XCTAssertEqual(simctl.commands, [["list", "devices", "--json"]])
    }

    // A lone worker tests on a destination that names no one simulator without a word, so that failure is told apart
    // from the others, which are said.
    func test_aDestinationThatNamesNoOneSimulator_isUnresolved_unlikeOtherFailures() async {
        let unresolved = [
            "platform=macOS",
            "platform=iOS Simulator,name=iPhone 3G",
            "id=00008120-001A2B3C4D5E601E",
        ]
        for destination in unresolved {
            let failure = await unavailable(preparing: 1, like: destination)
            XCTAssertEqual(failure?.destinationUnresolved, true, destination)
        }

        simctl = SimctlStandIn(list: list(of: [
            (name: "iPhone 17", udid: "AAAAAAAA-0000-0000-0000-000000000000"),
            (name: "iPhone 17", udid: "BBBBBBBB-0000-0000-0000-000000000000"),
        ]))
        let several = await unavailable(preparing: 1, like: "platform=iOS Simulator,name=iPhone 17")
        XCTAssertEqual(several?.destinationUnresolved, true)

        simctl = SimctlStandIn(list: Data("not JSON".utf8))
        let unreadable = await unavailable(preparing: 1, like: "id=\(iPhone17Pro)")
        XCTAssertEqual(unreadable?.destinationUnresolved, false)

        simctl = SimctlStandIn(list: fixture)
        simctl.answering { ["clone", "create"].contains($0.first) ? .init(status: 1, errors: "failed\n") : nil }
        for udid in [iPhone17Pro, bootedTwin] {
            let notMade = await unavailable(preparing: 1, like: "id=\(udid)")
            XCTAssertEqual(notMade?.destinationUnresolved, false, udid)
        }

        simctl.answering { $0.first == "bootstatus" ? .init(status: 1) : nil }
        let made = [WorkerSimulator(udid: "SIM-0", name: "w0", destination: "id=SIM-0")]
        let notBooted = await failure { try await self.makeSimulators().boot(made) }
        XCTAssertEqual(notBooted?.destinationUnresolved, false)
    }

    // MARK: - Helpers

    var fixture: Data? {
        FileManager.default.contents(atPath: "\(fixturesDirectory)/Simctl/devices.json")
    }

    /// Simulators made by `owner`, with only `running`, and `owner`, still running.
    func makeSimulators(running: Set<RecordedProcess> = []) -> WorkerSimulators {
        let stillRunning = running.union([owner])
        current.process = { [simctl] in simctl }
        return WorkerSimulators(owner: owner) { stillRunning.contains($0) }
    }

    /// The reason `prepare` gave for not making `count` simulators like `destination`, or nil if it made them.
    func failingToPrepare(
        _ count: Int,
        like destination: String,
        with simulators: WorkerSimulators? = nil
    ) async -> String? {
        let preparing = simulators ?? makeSimulators()
        let project = mutatedProject
        return await reason { try await preparing.prepare(count, like: destination, for: project) }
    }

    /// Why `prepare` didn't make `count` simulators like `destination`, or nil if it made them.
    func unavailable(preparing count: Int, like destination: String) async -> WorkerSimulatorsUnavailable? {
        let simulators = makeSimulators()
        let project = mutatedProject
        return await failure { try await simulators.prepare(count, like: destination, for: project) }
    }

    /// Why `work` didn't make or boot simulators, or nil if it did.
    func failure(of work: () async throws -> some Any) async -> WorkerSimulatorsUnavailable? {
        do {
            _ = try await work()
            return nil
        } catch {
            return error as? WorkerSimulatorsUnavailable
        }
    }

    /// The reason `work` gave for not making or booting simulators, or nil if it gave none.
    func reason(of work: () async throws -> some Any) async -> String? {
        do {
            _ = try await work()
            return nil
        } catch {
            return (error as? WorkerSimulatorsUnavailable)?.reason ?? "\(error)"
        }
    }

    /// simctl's JSON list of shut-down iPhone 17s on iOS 26.5 with these names and UDIDs.
    func list(of devices: [(name: String, udid: String)]) -> Data {
        let entries = devices.map { device in
            """
            {"udid": "\(device.udid)", "name": "\(device.name)", "state": "Shutdown", "isAvailable": true,
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"}
            """
        }
        return Data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [\(entries.joined(separator: ","))]}}
        """.utf8)
    }
}
