@testable import muterCore
import XCTest

/// Workers whose simulators were made anew, as the destination's simulator wasn't shut down, lack its settings and
/// data. A check run that then fails, on its tests rather than its simulator, says how the next run can clone it.
extension PerformMutationTestingXcodeWorkersTests {
    func test_aFailedCheckRun_onSimulatorsMadeAnew_saysHowTheNextRunCanCloneTheDestinationsSimulator() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, "** TEST FAILED **")
        workerSimulators.preparingAnew(from: .iPhone17Pro("Booted"))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.sentence), [
            "👷 Testing one mutant at a time, though 2 workers were asked for: worker 1's run with no mutant on, on its "
                + "simulator, didn't pass (its log is no-mutant run worker 1.log). Your iPhone 17 Pro was booted when "
                + "the workers' simulators were made, so they were new ones, without its settings and data: if it is "
                + "booted once this run has ended, shut it down "
                + "(`xcrun simctl shutdown 693E96A4-A11F-4223-B131-CFC50C9A17B8`), and the next run clones it.",
        ])
        assertTestedOnOneWorker()
    }

    // A run past the timeout says how the next run can clone it even if its log shows simulator trouble before it
    // hung, as that trouble didn't end the run.
    func test_aCheckRunPastTheBuildTimeout_onSimulatorsMadeAnew_saysHowTheNextRunCanCloneIt() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            buildTimeout: 900
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.endingsWithoutBuildingWritingTo["no-mutant run worker 1"] = .timedOut
        let deviceGone = loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")
        XCTAssertNotNil(SimulatorTrouble.first(inLog: deviceGone), "trouble that fails a run on time")
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, deviceGone)
        workerSimulators.preparingAnew(from: .iPhone17Pro("Booted"))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.unsupportedReason), [
            "worker 1's run with no mutant on, on its simulator, didn't end within 900 s (buildTimeout) (its log is "
                + "no-mutant run worker 1.log). Your iPhone 17 Pro was booted when the workers' simulators were made, "
                + "so they were new ones, without its settings and data: if it is booted once this run has ended, shut "
                + "it down (`xcrun simctl shutdown 693E96A4-A11F-4223-B131-CFC50C9A17B8`), and the next run clones it",
        ])
    }

    // Clones have its settings and data, so a failure on them says nothing of it.
    func test_aFailedCheckRun_onClones_saysNothingOfTheDestinationsSimulator() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, "** TEST FAILED **")
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.unsupportedReason), [
            "worker 1's run with no mutant on, on its simulator, didn't pass (its log is no-mutant run worker 1.log)",
        ])
    }

    // A simulator that is gone, or that failed twice to launch the run, failed it, not what it lacked.
    func test_aCheckRunWhoseLogShowsSimulatorTrouble_saysNothingOfTheDestinationsSimulator() async throws {
        workerSimulators.preparingAnew(from: .iPhone17Pro("Booted"))
        let choices = sentChoices()
        let logs = [
            "SimulatorTrouble/deviceGone_unableToFind.log",
            "SimulatorTrouble/launch_beforeEstablishingConnection.log",
        ]
        for fixture in logs {
            ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
            ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, loadFixture(fixture))

            _ = try await sut.run(with: state)
        }

        XCTAssertEqual(choices().count, 2)
        for reason in choices().map(\.unsupportedReason) {
            XCTAssertEqual(reason?.hasPrefix("worker 1's run with no mutant on, on its simulator, didn't pass: "), true)
            XCTAssertEqual(reason?.hasSuffix(" (its log is no-mutant run worker 1.log)"), true, reason ?? "")
            XCTAssertEqual(reason?.contains("xcrun simctl shutdown"), false, reason ?? "")
        }
    }

    // A check run that never started, as its `.xctestrun` couldn't be written, says nothing of what its simulator
    // lacked.
    func test_aCheckRunThatNeverStarted_saysNothingOfTheDestinationsSimulator() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.switchOnFails = { $0 == .null }
        ioDelegate.whileRunningBaseline = { [ioDelegate] _ in
            ioDelegate.switchOnError = CocoaError(.fileWriteNoPermission)
        }
        workerSimulators.preparingAnew(from: .iPhone17Pro("Booted"))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        let reasons = choices().compactMap(\.unsupportedReason)
        XCTAssertEqual(reasons.count, 1)
        let reason = reasons.first ?? ""
        XCTAssertTrue(reason.hasPrefix("worker 0's run with no mutant on, on its simulator, didn't pass"), reason)
        XCTAssertFalse(reason.contains("xcrun simctl shutdown"), reason)
    }

    // The state is said as simctl listed it when the workers' simulators were made: not shut down, if not booted.
    func test_theDestinationsSimulator_isSaidInTheStateItWasIn() async throws {
        let saidOfStates = [
            "Shutting Down": "was shutting down",
            "Booting": "was booting",
            "Creating": "was still being created",
            "Unknown": "was in state Unknown",
        ]
        for (listed, said) in saidOfStates {
            let hint = SimulatorWorkerSetup.cloningHint(for: .iPhone17Pro(listed), simulators: 2)
            XCTAssertTrue(hint.hasPrefix("Your iPhone 17 Pro \(said) when the workers' simulators were made, "), hint)
        }

        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (.failed, "** TEST FAILED **")
        workerSimulators.preparingAnew(from: .iPhone17Pro("Shutting Down"))
        let choices = sentChoices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(choices().map(\.unsupportedReason), [
            "worker 1's run with no mutant on, on its simulator, didn't pass (its log is no-mutant run worker 1.log). "
                + "Your iPhone 17 Pro was shutting down when the workers' simulators were made, so they were new ones, "
                + "without its settings and data: if it is booted once this run has ended, shut it down "
                + "(`xcrun simctl shutdown 693E96A4-A11F-4223-B131-CFC50C9A17B8`), and the next run clones it",
        ])
    }
}

extension SimctlDevice {
    /// The iPhone 17 Pro on iOS 26.5 that the suites' `-destination` names, as simctl lists it in `state`.
    static func iPhone17Pro(_ state: String) -> SimctlDevice {
        SimctlDevice(
            udid: "693E96A4-A11F-4223-B131-CFC50C9A17B8",
            name: "iPhone 17 Pro",
            state: state,
            isAvailable: true,
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
        )
    }
}
