@testable import muterCore
import XCTest

/// An xcodebuild run that tests in parallel, on clones of the simulator, names a failed test in no line that stops
/// it: a lone worker on the test command's destination then can't stop, unlike one on a simulator of its own.
extension ConfigurationParsingTests {
    func test_stopsAtFirstFailure_underXcodebuild_isOffForAWorkerOnTheDestinationThatTestsInParallel() {
        let destination = "platform=iOS Simulator,name=iPhone 17"
        let configuration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"]
        ).withStopFacts(firstDestinationIsASimulator: false, uiTestTargets: [], destinationRunsInParallel: true)
        let onTheDestination = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        let onItsOwnSimulator = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project.DerivedData.noindex",
            testDiagnosticsOff: true,
            destination: "platform=iOS Simulator,id=SIM-0",
            parallelTestingOff: true
        )

        let parallel = configuration.forXcodeWorker(onTheDestination)
        XCTAssertFalse(parallel.stopsAtFirstFailure)
        let reason = parallel.stopAtFirstFailureUnsupportedReason ?? ""
        XCTAssertTrue(reason.contains("`-destination \(destination)` tests in parallel"), reason)
        XCTAssertTrue(reason.contains("-parallel-testing-enabled NO"), reason)
        XCTAssertTrue(configuration.forXcodeWorker(onItsOwnSimulator).stopsAtFirstFailure)
        // Before the workers are known, whose simulators of their own would test one test at a time.
        XCTAssertTrue(configuration.stopsAtFirstFailure)
        // Testing one at a time, a worker on the destination stops.
        let serial = configuration.withStopFacts(firstDestinationIsASimulator: false, uiTestTargets: [])
        XCTAssertTrue(serial.forXcodeWorker(onTheDestination).stopsAtFirstFailure)
    }

    func test_destinationRunsInParallel_followsTheTestArguments_elseTheXctestrun() {
        let target: [String: AnyHashable] = ["BlueprintName": "AppTests", "ParallelizationEnabled": true]
        let targets: [AnyHashable] = [target]
        let testConfiguration: [String: AnyHashable] = ["Name": "Test Scheme Action", "TestTargets": targets]
        let parallelizes = XCTestRun(["TestConfigurations": [testConfiguration] as [AnyHashable]])
        let cases: [(arguments: [String], expected: Bool)] = [
            (["test"], true),
            (["-parallel-testing-worker-count", "2", "test"], true),
            (["-parallel-testing-enabled", "NO", "test"], false),
        ]
        for (arguments, expected) in cases {
            let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments)

            XCTAssertEqual(configuration.destinationRunsInParallel(given: parallelizes), expected, "\(arguments)")
        }
        let yes = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["-parallel-testing-enabled", "YES"])
        XCTAssertTrue(yes.destinationRunsInParallel(given: XCTestRun()))
        let unset = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        XCTAssertFalse(unset.destinationRunsInParallel(given: XCTestRun()))
    }
}
