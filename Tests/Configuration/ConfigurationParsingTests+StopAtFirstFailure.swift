@testable import muterCore
import XCTest

/// Which xcodebuild runs can stop at their first failed test: those on a simulator, and those on a Mac whose tests no
/// app hosts (`ConfigurationParsingTests+StoppingOnAMac`).
extension ConfigurationParsingTests {
    func test_stopsAtFirstFailure_underXcodebuild_onEachKindOfSimulatorDestination() {
        let destinations = [
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=iOS Simulator,id=693E96A4-0E5B-4F3A-9E4C-2A39F5C8D1B7",
            "platform=tvOS Simulator,name=Apple TV",
            "platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)",
            "platform=visionOS Simulator,name=Apple Vision Pro",
            " platform = iOS Simulator , name = iPhone 17 ",
        ]
        for destination in destinations {
            let configuration = xcodebuild(testingOn: destination)

            XCTAssertNil(configuration.stopAtFirstFailureUnsupportedReason, destination)
            XCTAssertTrue(configuration.stopsAtFirstFailure, destination)
        }
    }

    // Nothing measured that killing xcodebuild ends a device's tests; a `generic/` destination names no one device.
    func test_stopsAtFirstFailure_underXcodebuild_isOffOnADeviceOrAGenericDestination() {
        let cases: [(destination: String, reasonNames: String)] = [
            ("platform=iOS,id=00008110-000A1B2C3D4E5F6A", "doesn't name"),
            ("platform=iOS,name=Joe's iPhone", "doesn't name"),
            ("platform=visionOS,name=Apple Vision Pro", "doesn't name"),
            ("generic/platform=iOS Simulator", "any device of a platform"),
            ("generic/platform=iOS", "any device of a platform"),
            ("generic/platform=macOS", "any device of a platform"),
            ("arch=arm64", "doesn't name"),
        ]
        for (destination, reasonNames) in cases {
            for key in [ConfigurationSwitch.unset, .enabled] {
                let configuration = xcodebuild(testingOn: destination, stopAtFirstFailure: key)
                    .withMacWorkerFact(given: .unhostedFixture)

                XCTAssertFalse(configuration.stopsAtFirstFailure, destination)
                let reason = configuration.stopAtFirstFailureUnsupportedReason ?? ""
                XCTAssertTrue(reason.contains(reasonNames), "\(destination): \(reason)")
                XCTAssertTrue(reason.contains("`-destination \(destination)`"), "\(destination): \(reason)")
            }
        }
    }

    // A bare `id=` or `name=` can be a device too: only simctl's list says it is a simulator.
    func test_stopsAtFirstFailure_underXcodebuild_onADestinationWithNoPlatform_onlyWhenSimctlListsIt() {
        for destination in ["id=693E96A4-0E5B-4F3A-9E4C-2A39F5C8D1B7", "name=iPhone 17 Pro"] {
            let configuration = xcodebuild(testingOn: destination)

            XCTAssertFalse(configuration.stopsAtFirstFailure, destination)
            let reason = configuration.stopAtFirstFailureUnsupportedReason ?? ""
            XCTAssertTrue(reason.contains("simctl lists none"), reason)
            let listed = configuration.withStopFacts(firstDestinationIsASimulator: true, uiTestTargets: [])
            XCTAssertTrue(listed.stopsAtFirstFailure, destination)
        }
    }

    // Only the first `-destination` counts: a mutant's run tests on it alone. The Mac's tests aren't known to run
    // unhosted here, so a run on it doesn't stop.
    func test_stopsAtFirstFailure_underXcodebuild_followsTheFirstDestination() {
        let simulatorFirst = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "-destination", "platform=macOS"]
        )
        let macFirst = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=macOS", "-destination", "platform=iOS Simulator,name=iPhone 17"]
        )

        XCTAssertTrue(simulatorFirst.stopsAtFirstFailure)
        XCTAssertFalse(macFirst.stopsAtFirstFailure)
    }

    // A worker's simulator is one SwiftMutator made, whatever its destination says.
    func test_stopsAtFirstFailure_underXcodebuild_onAWorkersOwnSimulator() {
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/project_worker1.DerivedData.noindex",
            testDiagnosticsOff: true,
            destination: "id=SIM-1",
            parallelTestingOff: true
        )
        let onTheDestination = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        let configuration = xcodebuild(testingOn: "id=693E96A4-0E5B-4F3A-9E4C-2A39F5C8D1B7")

        XCTAssertTrue(configuration.forXcodeWorker(worker).stopsAtFirstFailure)
        // A lone worker on the test command's destination tests where that destination says.
        XCTAssertFalse(configuration.forXcodeWorker(onTheDestination).stopsAtFirstFailure)
    }

    // As `swift test --repeat-until`: a failure that a retry passes doesn't decide the run.
    func test_stopsAtFirstFailure_underXcodebuild_isOffWhenFailingTestsAreRetried() {
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-destination", "platform=iOS Simulator,name=iPhone 17", "-test-iterations", "3",
                "-retry-tests-on-failure", "test",
            ],
            stopAtFirstFailure: .enabled
        )
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/project_worker1.DerivedData.noindex",
            testDiagnosticsOff: true,
            destination: "platform=iOS Simulator,id=SIM-1"
        )

        XCTAssertFalse(configuration.stopsAtFirstFailure)
        XCTAssertFalse(configuration.forXcodeWorker(worker).stopsAtFirstFailure)
        let reason = configuration.stopAtFirstFailureUnsupportedReason ?? ""
        XCTAssertTrue(reason.contains("-retry-tests-on-failure"), reason)
    }

    // The app a UI test drives can outlive a stopped xcodebuild, which #81's measurement didn't cover.
    func test_stopsAtFirstFailure_underXcodebuild_isOffWhenTheRunTestsAUITestTarget() {
        let configuration = xcodebuild(testingOn: "platform=iOS Simulator,name=iPhone 17")
            .withStopFacts(firstDestinationIsASimulator: false, uiTestTargets: ["AppUITests"])

        XCTAssertFalse(configuration.stopsAtFirstFailure)
        let reason = configuration.stopAtFirstFailureUnsupportedReason ?? ""
        XCTAssertTrue(reason.contains("`AppUITests`"), reason)
        XCTAssertTrue(reason.contains("-skip-testing"), reason)
    }

    func test_targetsTested_leavesOutWhatTheTestArgumentsSkipOrDontSelect() {
        let targets = ["AppUITests", "WidgetUITests"]
        let cases: [(arguments: [String], expected: [String])] = [
            (["test"], targets),
            (["-skip-testing:AppUITests", "test"], ["WidgetUITests"]),
            (["-skip-testing", "AppUITests", "-skip-testing:WidgetUITests"], []),
            // Skipping part of a target still runs the rest of it.
            (["-skip-testing:AppUITests/LoginTests"], targets),
            (["-only-testing:AppTests"], []),
            (["-only-testing:AppTests", "-only-testing:WidgetUITests/SnapshotTests/testSmall"], ["WidgetUITests"]),
            (["-only-testing", "AppUITests"], ["AppUITests"]),
            // Tests named in a file it doesn't read could be any of them.
            (["-only-testing", "@tests.txt"], targets),
            (["-only-testing:@tests.txt", "-skip-testing:AppUITests"], ["WidgetUITests"]),
        ]
        for (arguments, expected) in cases {
            let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments)

            XCTAssertEqual(configuration.targetsTested(among: targets), expected, "\(arguments)")
        }
    }

    // MARK: - Helpers

    private func xcodebuild(
        testingOn destination: String,
        stopAtFirstFailure: ConfigurationSwitch = .unset
    ) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            stopAtFirstFailure: stopAtFirstFailure
        )
    }
}
