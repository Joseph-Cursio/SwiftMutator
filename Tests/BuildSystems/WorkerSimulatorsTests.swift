@testable import muterCore
import XCTest

/// `WorkerSimulators` with a stand-in for `xcrun simctl`, which answers `list devices --json` with the fixture
/// `SimulatorDestinationTests` reads, or a list a test gives, and records every command. No simulator is touched.
final class WorkerSimulatorsTests: MuterTestCase {
    private let iPhone17Pro = "693E96A4-A11F-4223-B131-CFC50C9A17B8" // Shutdown, iOS 26.5
    private let bootedTwin = "461B8A08-7CE1-43BD-8F86-1812452225FB" // Booted, an iPhone 17 on iOS 26.5
    private let mutatedProject = URL(fileURLWithPath: "/tmp/App_mutated")
    /// The first 8 hex digits of the SHA-256 of `/tmp/App_mutated`.
    private let projectHash = "fd200ba3"
    private let owner = RecordedProcess(id: 4242, started: 1_700_000_000_123_456)
    private var simctl = SimctlStandIn(list: nil)

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
        XCTAssertTrue(printed?.hasSuffix("` printed no UDID") == true, printed ?? "")

        simctl.answering { $0.first == "clone" ? .init(status: SIGKILL, endedBySignal: true, timedOut: true) : nil }
        let timedOut = await failingToPrepare(1, like: "id=\(iPhone17Pro)")
        XCTAssertTrue(timedOut?.hasSuffix("` didn't finish within 60 seconds") == true, timedOut ?? "")
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

    // MARK: - Booting them

    func test_boot_waitsForEverySimulatorAtOnce_withATimeLimit() async throws {
        let made = (0..<3).map { WorkerSimulator(udid: "SIM-\($0)", name: "w\($0)", destination: "id=SIM-\($0)") }
        simctl.holdingBootsUntil(3)

        try await makeSimulators().boot(made)

        XCTAssertEqual(
            Set(simctl.commands),
            [["bootstatus", "SIM-0", "-b"], ["bootstatus", "SIM-1", "-b"], ["bootstatus", "SIM-2", "-b"]]
        )
        XCTAssertEqual(simctl.timeLimits, [300, 300, 300])
        XCTAssertEqual(simctl.mostBootsAtOnce, 3)
    }

    func test_aSimulatorThatDoesntBoot_failsTheBoot() async {
        let made = (0..<2).map { WorkerSimulator(udid: "SIM-\($0)", name: "w\($0)", destination: "id=SIM-\($0)") }
        simctl.answering { arguments in
            guard arguments == ["bootstatus", "SIM-1", "-b"] else { return nil }
            return .init(status: SIGKILL, endedBySignal: true, timedOut: true)
        }

        let error = await reason(of: { try await self.makeSimulators().boot(made) })

        XCTAssertEqual(error, "`xcrun simctl bootstatus SIM-1 -b` didn't finish within 300 seconds")
    }

    // A failed baseline cancels the boot, which would otherwise hold up the run's end until the simulators booted.
    func test_aBootThatIsCancelled_killsSimctl() async {
        let made = [WorkerSimulator(udid: "SIM-0", name: "w0", destination: "id=SIM-0")]
        simctl.holdingBootsUntilKilled()
        let simulators = makeSimulators()

        let boot = Task { try await simulators.boot(made) }
        let deadline = Date().addingTimeInterval(5)
        while simctl.commands.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        boot.cancel()
        let result = await boot.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(simctl.treesKilled, 1)
    }

    func test_aBootInACancelledTask_startsNoSimctl() async {
        let made = [WorkerSimulator(udid: "SIM-0", name: "w0", destination: "id=SIM-0")]
        let simulators = makeSimulators()

        let boot = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await simulators.boot(made)
        }
        let result = await boot.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(simctl.commands, [])
    }

    // MARK: - Removing them

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
        await simulators.removeAll()

        let deletes = Array(simctl.commands.dropFirst(commandsBefore))
        XCTAssertEqual(Set(deletes), Set(made.map { ["delete", $0.udid] }))
        XCTAssertEqual(deletes.count, 2, "each once, the failed one included")
        XCTAssertEqual(simulators.recorded, [])
    }

    func test_removeAll_withNothingMade_startsNoProcess() async {
        await makeSimulators().removeAll()

        XCTAssertEqual(simctl.commands, [])
    }

    // MARK: - Sweeping what ended runs left

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

    func test_theSweep_ofTheFixture_deletesNothing() async {
        await makeSimulators().sweep(mutatedProject)

        XCTAssertEqual(simctl.commands, [["list", "devices", "--json"]])
    }

    func test_theSweep_withNoList_deletesNothing() async {
        simctl = SimctlStandIn(list: nil)

        await makeSimulators().sweep(mutatedProject)

        XCTAssertEqual(simctl.commands, [["list", "devices", "--json"]])
    }

    // MARK: - Helpers

    private var fixture: Data? {
        FileManager.default.contents(atPath: "\(fixturesDirectory)/Simctl/devices.json")
    }

    /// Simulators made by `owner`, with only `running`, and `owner`, still running.
    private func makeSimulators(running: Set<RecordedProcess> = []) -> WorkerSimulators {
        let running = running.union([owner])
        current.process = { [simctl] in simctl }
        return WorkerSimulators(owner: owner, isRunning: { running.contains($0) })
    }

    /// The reason `prepare` gave for not making `count` simulators like `destination`, or nil if it made them.
    private func failingToPrepare(
        _ count: Int,
        like destination: String,
        with simulators: WorkerSimulators? = nil
    ) async -> String? {
        let simulators = simulators ?? makeSimulators()
        let mutatedProject = mutatedProject
        return await reason(of: { try await simulators.prepare(count, like: destination, for: mutatedProject) })
    }

    /// The reason `work` gave for not making or booting simulators, or nil if it gave none.
    private func reason(of work: () async throws -> some Any) async -> String? {
        do {
            _ = try await work()
            return nil
        } catch {
            return (error as? WorkerSimulatorsUnavailable)?.reason ?? "\(error)"
        }
    }

    /// simctl's JSON list of shut-down iPhone 17s on iOS 26.5 with these names and UDIDs.
    private func list(of devices: [(name: String, udid: String)]) -> Data {
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

/// `xcrun simctl`: `list devices --json` prints `list`, and every other command succeeds with no output unless
/// `answering` says otherwise. Commands may run at once, from any thread.
private final class SimctlStandIn: MuterProcess, @unchecked Sendable { // every `var` it changes is behind `lock`
    struct Answer {
        var status: Int32 = 0
        var endedBySignal = false
        var output = ""
        var errors = ""
        var timedOut = false
    }

    private let lock = NSLock()
    private let list: Data?
    private var answer: @Sendable ([String]) -> Answer? = { _ in nil }
    private var started: [(arguments: [String], timeLimit: TimeInterval?)] = []
    private var bootsToHoldFor = 0
    private var bootsHeldUntilKilled = false
    private var killed = 0
    private var bootsUnderWay = 0
    private var mostBoots = 0

    init(list: Data?) {
        self.list = list
    }

    /// Each command run, after `xcrun simctl`, in the order they started.
    var commands: [[String]] { lock.withLock { started.map(\.arguments) } }
    var timeLimits: [TimeInterval?] { lock.withLock { started.map(\.timeLimit) } }
    /// The most `bootstatus` commands that ran at once.
    var mostBootsAtOnce: Int { lock.withLock { mostBoots } }
    /// How many times a command was killed, with every process it started.
    var treesKilled: Int { lock.withLock { killed } }

    /// Gives `answer`'s answer to a command, where it gives one.
    func answering(_ answer: @escaping @Sendable ([String]) -> Answer?) {
        lock.withLock { self.answer = answer }
    }

    /// Has each `bootstatus` wait until `count` are under way, for at most 5 seconds, so that boots run one after
    /// another show as one at a time.
    func holdingBootsUntil(_ count: Int) {
        lock.withLock { bootsToHoldFor = count }
    }

    /// Has each `bootstatus` wait until a command is killed, for at most 5 seconds, and then end by SIGKILL.
    func holdingBootsUntilKilled() {
        lock.withLock { bootsHeldUntilKilled = true }
    }

    func runCommand(url: String, arguments args: [String], timeLimit: TimeInterval?) async -> CommandResult? {
        guard url == "/usr/bin/xcrun", args.first == "simctl" else {
            return nil
        }
        let arguments = Array(args.dropFirst())
        let answering = lock.withLock {
            started.append((arguments, timeLimit))
            return answer
        }
        let answer = answering(arguments)
        if arguments.first == "bootstatus", lock.withLock({ bootsHeldUntilKilled }) {
            let deadline = Date().addingTimeInterval(5)
            while lock.withLock({ killed }) == 0, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return CommandResult(status: SIGKILL, endedBySignal: true, output: "", errors: "")
        }
        if arguments.first == "bootstatus" {
            await holdBoot()
        }
        if arguments == ["list", "devices", "--json"], answer == nil {
            guard let list else {
                return CommandResult(status: 1, endedBySignal: false, output: "", errors: "simctl failed")
            }
            return CommandResult(
                status: 0,
                endedBySignal: false,
                output: String(decoding: list, as: UTF8.self),
                errors: ""
            )
        }
        let given = answer ?? Answer()
        return CommandResult(
            status: given.status,
            endedBySignal: given.endedBySignal,
            output: given.output,
            errors: given.errors,
            timedOut: given.timedOut
        )
    }

    private func holdBoot() async {
        let holdFor = lock.withLock {
            bootsUnderWay += 1
            mostBoots = max(mostBoots, bootsUnderWay)
            return bootsToHoldFor
        }
        let deadline = Date().addingTimeInterval(5)
        while lock.withLock({ mostBoots }) < holdFor, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        lock.withLock { bootsUnderWay -= 1 }
    }

    var processIdentifier: Int32 { 0 }
    var terminationStatus: Int32 { 0 }
    var terminationReason: Foundation.Process.TerminationReason { .exit }
    var terminationHandler: (@Sendable (Foundation.Process) -> Void)?
    var environment: [String: String]?
    var arguments: [String]?
    var executableURL: URL?
    var currentDirectoryURL: URL?
    var standardOutput: Any?
    var standardError: Any?

    func runProcess(url: String, arguments args: [String]) async -> Data? { nil }

    func run() throws {}

    func terminate() {}

    func interrupt() {}

    func terminateTree() {
        lock.withLock { killed += 1 }
    }
}
