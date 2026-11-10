@testable import muterCore
import XCTest

extension WorkerSimulatorsTests {
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

        let error = await reason { try await self.makeSimulators().boot(made) }

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
}
