@testable import muterCore
import XCTest

/// The fixtures are real xcodebuild 27.2 logs of `test-without-building` runs on iOS 26.5 simulators, with home
/// folders, the app's bundle ID and the Mac's and a device's names and IDs made anonymous. The `mutantCrash_` ones are
/// `launch_beforeEstablishingConnection.log` with only its signal changed.
final class SimulatorTroubleTests: MuterTestCase {
    private let xcodebuild = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])

    // Right after a run on the same simulator: SpringBoard was still busy, so the app never launched, and no test ran.
    func test_aSimulatorStillBusyWithTheRunBefore_isALaunchFailure() {
        let log = loadFixture("SimulatorTrouble/launch_preflightBusy.log")

        XCTAssertEqual(
            SimulatorTrouble.first(inLog: log),
            .launch(line: "Simulator device failed to launch com.example.MacCloud-client-iOS.")
        )
    }

    // Two runs at once on one simulator: the second's app was killed before its tests connected.
    func test_anAppKilledBeforeItsTestsConnected_isALaunchFailure() {
        let log = loadFixture("SimulatorTrouble/launch_beforeEstablishingConnection.log")

        XCTAssertEqual(
            SimulatorTrouble.first(inLog: log),
            .launch(
                line: "MacCloud_client_iOS encountered an error "
                    + "(Test crashed with signal kill before establishing connection.)"
            )
        )
    }

    // The app crashed at launch, before its tests connected, as when a mutant crashes it: the same log as an app that
    // was killed, but for the signal, which is the app's own.
    func test_anAppThatCrashedBeforeItsTestsConnected_isNoTrouble() {
        for signal in ["abrt", "segv", "trap"] {
            let log = loadFixture("SimulatorTrouble/mutantCrash_\(signal)BeforeEstablishingConnection.log")

            XCTAssertTrue(log.contains("Test crashed with signal \(signal) before establishing connection."), signal)
            XCTAssertNil(SimulatorTrouble.first(inLog: log), signal)
            XCTAssertNil(SimulatorTrouble.of(TestRun(outcome: .failed, testLog: log), with: xcodebuild), signal)
        }
        for signal in ["bus", "ill", "fpe"] {
            let line = "\tMacCloud_client_iOS encountered an error "
                + "(Test crashed with signal \(signal) before establishing connection.)"

            XCTAssertNil(SimulatorTrouble.first(inLog: line), line)
        }
    }

    // The simulator was deleted before the run: xcodebuild can't resolve the destination, and prints no summary.
    func test_aDestinationNoDeviceMatches_isAGoneDevice() {
        let log = loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")

        XCTAssertEqual(
            SimulatorTrouble.first(inLog: log),
            .deviceGone(
                line: "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
            )
        )
    }

    // The simulator was deleted while the tests ran: the test under way never ended, so its summary names it failing,
    // but no line shows its failure, and xcodebuild says the device is gone.
    func test_aDeviceDeletedMidRun_isAGoneDevice_thoughItsSummaryListsAFailingTest() {
        let log = loadFixture("SimulatorTrouble/deviceGone_deletedMidRun.log")

        XCTAssertNil(FailedTestLine.first(inLog: log))
        XCTAssertEqual(
            SimulatorTrouble.first(inLog: log),
            .deviceGone(
                line: "No matching device (B564EE45-CFEB-4238-928C-5DF08A260581) in set at "
                    + "/Users/me/Library/Developer/CoreSimulator/Devices"
            )
        )
    }

    // Each of the lines, as xcodebuild prints them, shows its trouble on its own.
    func test_eachLineOfTrouble_isFoundOnItsOwn() {
        let launches = [
            "Failure Reason: Application failed preflight checks",
            "2026-11-03 07:44:01.947 xcodebuild[97939:184995283] [MT] IDELaunchReport: "
                + "481b3180d587a80:481b3180d587a80: Finished with error: Simulator device failed to launch "
                + "com.example.MacCloud-client-iOS.",
            "\tMacCloud_client_iOS encountered an error (Failed to install or launch the test runner. "
                + "(Underlying Error: Simulator device failed to launch com.example.MacCloud-client-iOS.",
            "\tMacCloud_client_iOS encountered an error "
                + "(Test crashed with signal kill before establishing connection.)",
        ]
        let gone = [
            "xcodebuild: error: Unable to find a device matching the provided destination specifier:",
            "\tNo matching device (B564EE45-CFEB-4238-928C-5DF08A260581) in set at /Users/me/Library/Developer/"
                + "CoreSimulator/Devices",
        ]

        for line in launches {
            XCTAssertEqual(SimulatorTrouble.first(inLog: line), .launch(line: line.trimmed), line)
        }
        for line in gone {
            XCTAssertEqual(SimulatorTrouble.first(inLog: line), .deviceGone(line: line.trimmed), line)
        }
    }

    // A failed test makes the run the mutant's kill, whatever went wrong after it.
    func test_aLaunchFailureNextToAFailedTest_isNoTrouble() {
        let failedTests = [
            "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 1 + 1 == 3",
            "Test Case '-[CalcTests.CalcTests test_inRange]' failed (0.001 seconds).",
            // Parallel testing's, as a baseline can print, the same for a failed test or a crash.
            "Test case 'MacCloudUserFirstSeenTests/refreshingIsIdempotent()' failed on "
                + "'Clone 1 of iPhone 17 Pro - MacCloud_client_iOS (67864)' (0.011 seconds)",
        ]
        let trouble = [
            "\tSimulator device failed to launch com.example.MacCloud-client-iOS.",
            "\tNo matching device (B564EE45-CFEB-4238-928C-5DF08A260581) in set at /Users/me/Library",
        ]

        for failedTest in failedTests {
            for line in trouble {
                let log = "\(failedTest)\nTesting failed:\n\(line)\n\n** TEST EXECUTE FAILED **"
                XCTAssertNil(SimulatorTrouble.first(inLog: log), log)
            }
        }
    }

    // Logs of mutants that failed a test or crashed, which say nothing of the simulator.
    func test_aMutantsFailedTestOrCrash_isNoTrouble() {
        let logs = [
            "runtimeError_fatalError.log",
            "testRunWithFailures_swiftTesting.log",
            "testRunWithFailures_withTestFailedFooter.log",
            "coverageRun_xcodebuild_testFailed.log",
            "coverageRun_xcodebuild_testCrashed.log",
            "timeout_xcodebuildCrash.log",
            "timeout_xcodebuildFailedTestCase.log",
        ]

        for name in logs {
            let log = loadFixture("TestLogsForParsing/\(name)")
            XCTAssertFalse(log.isEmpty, name)
            XCTAssertNil(SimulatorTrouble.first(inLog: log), name)
        }
    }

    // A gone device is said before a failed launch: a run on it again wouldn't launch either.
    func test_aGoneDevice_comesBeforeALaunchFailure() {
        let log = """
            2026-11-03 07:44:01.946 xcodebuild[97939:184995283] [MT] Simulator device failed to launch com.example.App.
            Testing failed:
            \tNo matching device (B564EE45-CFEB-4238-928C-5DF08A260581) in set at /Users/me/Library
            """

        XCTAssertEqual(
            SimulatorTrouble.first(inLog: log),
            .deviceGone(line: "No matching device (B564EE45-CFEB-4238-928C-5DF08A260581) in set at /Users/me/Library")
        )
    }

    func test_aVeryLongLine_isCut() {
        let line = "Simulator device failed to launch " + String(repeating: "x", count: 1_000)

        XCTAssertEqual(SimulatorTrouble.first(inLog: line)?.line.count, FailedTestLine.lineLengthLimit)
    }

    // Only an xcodebuild run that didn't pass and wasn't stopped is looked at.
    func test_ofARun_looksOnlyAtAnXcodebuildRunThatFailed() {
        let log = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let launch = SimulatorTrouble.launch(line: "Simulator device failed to launch com.example.MacCloud-client-iOS.")

        XCTAssertEqual(SimulatorTrouble.of(TestRun(outcome: .failed, testLog: log), with: xcodebuild), launch)
        XCTAssertEqual(SimulatorTrouble.of(TestRun(outcome: .buildError, testLog: log), with: xcodebuild), launch)
        XCTAssertEqual(
            SimulatorTrouble.of(TestRun(outcome: .timeout, testLog: log, ending: .timedOut), with: xcodebuild),
            launch
        )
        XCTAssertNil(SimulatorTrouble.of(TestRun(outcome: .passed, testLog: log), with: xcodebuild))
        XCTAssertNil(SimulatorTrouble.of(TestRun(outcome: .failed, testLog: log, ending: .cancelled), with: xcodebuild))
        XCTAssertNil(SimulatorTrouble.of(TestRun(outcome: .failed, testLog: log), with: swift))
    }
}
