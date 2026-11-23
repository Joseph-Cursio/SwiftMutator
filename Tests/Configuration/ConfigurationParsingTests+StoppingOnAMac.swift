@testable import muterCore
import XCTest

/// The project's `.xctestrun`, not XCTest's class of the same name.
private typealias ProjectTestRun = muterCore.XCTestRun

/// An xcodebuild run on a Mac stops at its first failed test when every test target it tests runs in Xcode's `xctest`
/// agent, xcodebuild's own child, where killing xcodebuild's process tree was measured to end the tests: not a Mac
/// app's hosted tests, UI tests or Mac Catalyst, which nothing measured.
extension ConfigurationParsingTests {
    private static let hostedApp = ProjectTestRun.withTestTargets([
        "AppTests": ["TestHostPath": ProjectTestRun.macAppPath, "IsAppHostedTestBundle": true],
    ])

    // On by default, as on a simulator, with or without an `arch=`.
    func test_stopsAtFirstFailure_onAMac_whenNoAppHostsTheTests() {
        let destinations = ["platform=macOS", "platform=macOS,arch=arm64", " platform = macOS , arch = x86_64 "]
        for destination in destinations {
            for key in [ConfigurationSwitch.unset, .enabled] {
                let configuration = onAMac(destination, stopAtFirstFailure: key)
                    .withMacWorkerFact(given: .unhostedFixture)

                XCTAssertNil(configuration.stopAtFirstFailureUnsupportedReason, destination)
                XCTAssertTrue(configuration.stopsAtFirstFailure, destination)
            }
        }
    }

    // An app host isn't xcodebuild's child, so nothing measured that killing xcodebuild ends its tests. Before the
    // `.xctestrun` is read, the run can't tell, and doesn't stop either.
    func test_stopsAtFirstFailure_onAMac_isOffWhenAnAppHostsTheTests_orBeforeTheXctestrunIsRead() {
        let hosted = onAMac("platform=macOS", stopAtFirstFailure: .enabled).withMacWorkerFact(given: Self.hostedApp)
        let unread = onAMac("platform=macOS", stopAtFirstFailure: .enabled)

        for configuration in [hosted, unread] {
            XCTAssertFalse(configuration.stopsAtFirstFailure)
            XCTAssertEqual(
                configuration.stopAtFirstFailureUnsupportedReason,
                "under xcodebuild it works on a Mac only when every test target the run tests runs in Xcode's "
                    + "`xctest` agent, a child of xcodebuild, and on `-destination platform=macOS` an app hosts some "
                    + "of them, or the project's `.xctestrun` doesn't say: an app host isn't a child of xcodebuild, "
                    + "so nothing measured that stopping a run ends its tests; `-skip-testing:<target>` in "
                    + "`arguments` leaves a target out"
            )
        }
        // Skipping the hosted target leaves tests the agent runs.
        let skipping = onAMac("platform=macOS", arguments: ["-skip-testing:AppTests"])
            .withMacWorkerFact(given: ProjectTestRun.withTestTargets([
                "CoreTests": ["TestHostPath": ProjectTestRun.macAgentPath],
                "AppTests": ["TestHostPath": ProjectTestRun.macAppPath, "IsAppHostedTestBundle": true],
            ]))
        XCTAssertTrue(skipping.stopsAtFirstFailure)
    }

    // A UI test target's app can outlive a stopped run, on a Mac as on a simulator.
    func test_stopsAtFirstFailure_onAMac_isOffWhenTheRunTestsAUITestTarget() {
        let uiTests = ProjectTestRun.withTestTargets([
            "AppUITests": ["TestHostPath": "__TESTROOT__/Debug/AppUITests-Runner.app", "IsUITestBundle": true],
        ])
        let configuration = onAMac("platform=macOS").withMacWorkerFact(given: uiTests)
            .withStopFacts(firstDestinationIsASimulator: false, uiTestTargets: ["AppUITests"])

        XCTAssertFalse(configuration.stopsAtFirstFailure)
        let reason = configuration.stopAtFirstFailureUnsupportedReason ?? ""
        XCTAssertTrue(reason.contains("UI tests (`AppUITests`)"), reason)
    }

    func test_stopsAtFirstFailure_onMacCatalyst_isOff_evenWhenNoAppHostsTheTests() {
        for destination in ["platform=macOS,variant=Mac Catalyst", "platform=macOS,arch=arm64,variant=Mac Catalyst"] {
            let configuration = onAMac(destination, stopAtFirstFailure: .enabled)
                .withMacWorkerFact(given: .unhostedFixture)

            XCTAssertFalse(configuration.stopsAtFirstFailure, destination)
            XCTAssertEqual(
                configuration.stopAtFirstFailureUnsupportedReason,
                "under xcodebuild it works on a Mac only for tests that Xcode's `xctest` agent runs, and "
                    + "`-destination \(destination)` names Mac Catalyst, where nothing measured that stopping a run "
                    + "ends its tests"
            )
        }
    }

    func test_stopsAtFirstFailure_onAMac_isOffWhenFailingTestsAreRetried_orSwitchedOff() {
        let retrying = onAMac("platform=macOS", arguments: ["-retry-tests-on-failure"])
            .withMacWorkerFact(given: .unhostedFixture)
        let switchedOff = onAMac("platform=macOS", stopAtFirstFailure: .disabled)
            .withMacWorkerFact(given: .unhostedFixture)

        XCTAssertFalse(retrying.stopsAtFirstFailure)
        let reason = retrying.stopAtFirstFailureUnsupportedReason ?? ""
        XCTAssertTrue(reason.contains("-retry-tests-on-failure"), reason)
        XCTAssertFalse(switchedOff.stopsAtFirstFailure)
        XCTAssertNil(switchedOff.stopAtFirstFailureUnsupportedReason, "supported, but switched off")
    }

    // Each of several workers on a Mac tests one test at a time, so its runs stop whatever the destination's testing;
    // a lone worker on the destination that tests in parallel runs its tests in several processes, whose failures show
    // only in `failed on` lines, which never stop a run.
    func test_stopsAtFirstFailure_onAMac_isOffForALoneWorkerThatTestsInParallel_only() {
        let configuration = onAMac("platform=macOS").withMacWorkerFact(given: .unhostedFixture)
            .withStopFacts(firstDestinationIsASimulator: false, uiTestTargets: [], destinationRunsInParallel: true)
        let lone = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        let oneOfSeveral = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/project_mutated_worker1.DerivedData.noindex",
            testDiagnosticsOff: true,
            parallelTestingOff: true
        )

        let parallel = configuration.forXcodeWorker(lone)
        XCTAssertFalse(parallel.stopsAtFirstFailure)
        XCTAssertEqual(
            parallel.stopAtFirstFailureUnsupportedReason,
            "a run on `-destination platform=macOS` tests in parallel, in several test processes, whose failed tests "
                + "xcodebuild reports in lines that can't stop it; `-parallel-testing-enabled NO` in `arguments` "
                + "tests one at a time"
        )
        XCTAssertTrue(configuration.forXcodeWorker(oneOfSeveral).stopsAtFirstFailure)
        // Before the workers are known, and on a lone worker whose destination tests one test at a time.
        XCTAssertTrue(configuration.stopsAtFirstFailure)
        let serial = onAMac("platform=macOS").withMacWorkerFact(given: .unhostedFixture)
            .withStopFacts(firstDestinationIsASimulator: false, uiTestTargets: [])
        XCTAssertTrue(serial.forXcodeWorker(lone).stopsAtFirstFailure)
    }

    // MARK: - Helpers

    /// An xcodebuild test command on `destination`, with `arguments` before `test`.
    private func onAMac(
        _ destination: String,
        arguments: [String] = [],
        stopAtFirstFailure: ConfigurationSwitch = .unset
    ) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination] + arguments + ["test"],
            stopAtFirstFailure: stopAtFirstFailure
        )
    }
}
