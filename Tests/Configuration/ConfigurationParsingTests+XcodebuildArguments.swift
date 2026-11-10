@testable import muterCore
import XCTest

extension ConfigurationParsingTests {
    // Each run of a mutant keeps its derived data beside the copy, not in ~/Library/Developer/Xcode/DerivedData. The
    // `.xctestrun` takes the place of `-scheme`, and the run's own action of `test`.
    func test_testWithoutBuildArguments_forXcodebuild_addTheWorkersDerivedData() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
        )
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )

        XCTAssertEqual(xcode.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun", "muter.xctestrun",
        ])
        XCTAssertEqual(xcode.forXcodeWorker(worker).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun", "muter.xctestrun",
            "-derivedDataPath", "/path/App_mutated.DerivedData",
        ])
    }

    // Only when the xcodebuild in use takes it (see BuildForTesting).
    func test_testWithoutBuildArguments_forXcodebuild_turnOffTestDiagnosticsWhenTheWorkerSays() {
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["-destination", "platform=macOS"])
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        )

        XCTAssertEqual(xcode.forXcodeWorker(worker).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-derivedDataPath", "/path/App_mutated.DerivedData",
            "-collect-test-diagnostics", "never",
        ])
    }

    func test_testWithoutBuildArguments_forXcodebuild_useTheWorkersDestinationAndTestRunFile() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "-only-testing", "AppTests", "test"]
        )
        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker2.xctestrun",
            derivedData: "/path/App_mutated_worker2.DerivedData",
            destination: "platform=iOS Simulator,id=8C5A2F0E",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        )

        XCTAssertEqual(xcode.forXcodeWorker(worker).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,id=8C5A2F0E",
            "-xctestrun", "muter-worker2.xctestrun",
            "-only-testing", "AppTests",
            "-derivedDataPath", "/path/App_mutated_worker2.DerivedData",
            "-collect-test-diagnostics", "never",
            "-parallel-testing-enabled", "NO",
        ])
    }

    // What says which tests run and how holds for every mutant, as it did for the baseline (#123). What the
    // `.xctestrun` takes the place of, every action and `-destination`, and what would break or slow each run, are left
    // out, each with its value.
    func test_testWithoutBuildArguments_forXcodebuild_keepTheTestCommandsOwnArguments() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-workspace", "App.xcworkspace", "-project", "App.xcodeproj", "-scheme", "App", "-testPlan", "Unit",
                "-destination", "platform=macOS", "-destination", "platform=macOS,variant=Mac Catalyst",
                "-only-testing:AppTests", "-skip-testing:AppTests/SlowTests", "-only-test-configuration", "English",
                "-test-iterations", "3", "-retry-tests-on-failure", "-test-timeouts-enabled", "YES",
                "-skip-test-configuration", "German", "-run-tests-until-failure", "-testLanguage", "en",
                "-testRegion", "US", "-destination-timeout", "30", "-default-test-execution-time-allowance", "60",
                "-maximum-test-execution-time-allowance", "120",
                "-parallel-testing-worker-count", "2", "-configuration", "Debug", "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
                "-quiet", "-resultStreamPath", "stream.json", "-enableCodeCoverage", "NO", "-derivedDataPath", "DD",
                "-collect-test-diagnostics", "on-failure", "clean", "build", "test",
            ]
        )

        XCTAssertEqual(xcode.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-only-testing:AppTests", "-skip-testing:AppTests/SlowTests", "-only-test-configuration", "English",
            "-test-iterations", "3", "-retry-tests-on-failure", "-test-timeouts-enabled", "YES",
            "-skip-test-configuration", "German", "-run-tests-until-failure", "-testLanguage", "en",
            "-testRegion", "US", "-destination-timeout", "30", "-default-test-execution-time-allowance", "60",
            "-maximum-test-execution-time-allowance", "120",
            "-parallel-testing-worker-count", "2", "-configuration", "Debug", "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
            "-derivedDataPath", "DD",
            "-collect-test-diagnostics", "on-failure",
        ])
    }

    // xcodebuild takes `-derivedDataPath` and `-parallel-testing-enabled` once, so the worker's own replace the test
    // command's, as do its test diagnostics and, on a simulator of its own, everything that tunes parallel testing.
    func test_testWithoutBuildArguments_forXcodebuild_leaveOutWhatTheWorkerSetsItself() {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-destination", "platform=iOS Simulator,name=iPhone 17", "-derivedDataPath", "DD",
                "-collect-test-diagnostics", "on-failure", "-parallel-testing-enabled", "YES",
                "-maximum-parallel-testing-workers", "4", "-parallel-testing-worker-count", "2",
                "-parallelize-tests-among-destinations", "-skip-testing:AppUITests", "test",
            ]
        )
        let onTheDestination = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )
        let onASimulator = MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/path/App_mutated_worker1.DerivedData",
            destination: "platform=iOS Simulator,id=8C5A2F0E",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        )

        XCTAssertEqual(xcode.forXcodeWorker(onTheDestination).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,name=iPhone 17",
            "-xctestrun", "muter.xctestrun",
            "-collect-test-diagnostics", "on-failure", "-parallel-testing-enabled", "YES",
            "-maximum-parallel-testing-workers", "4", "-parallel-testing-worker-count", "2",
            "-parallelize-tests-among-destinations", "-skip-testing:AppUITests",
            "-derivedDataPath", "/path/App_mutated.DerivedData",
        ])
        XCTAssertEqual(xcode.forXcodeWorker(onASimulator).testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=iOS Simulator,id=8C5A2F0E",
            "-xctestrun", "muter-worker1.xctestrun",
            "-skip-testing:AppUITests",
            "-derivedDataPath", "/path/App_mutated_worker1.DerivedData",
            "-collect-test-diagnostics", "never",
            "-parallel-testing-enabled", "NO",
        ])
    }

    // xcodebuild runs every test any `-only-testing` names, so the test command's would undo the filter, which selects
    // tests of its own; `-skip-testing` still leaves out what it names.
    func test_testWithoutBuildArguments_forXcodebuild_withATestFilter_leaveOutOnlyTheTestCommandsOnlyTesting() throws {
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: [
                "-destination", "platform=macOS", "-only-testing:SortTests", "-only-testing", "ParseTests",
                "-skip-testing:SortTests/SlowProperties", "test",
            ],
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["SortTests/SortProperties"]
        )

        XCTAssertEqual(xcode.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-only-testing:SortTests", "-only-testing", "ParseTests", "-skip-testing:SortTests/SlowProperties",
        ])
        let filtered = try XCTUnwrap(xcode.withPropertyTestFilter())
        XCTAssertEqual(filtered.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "-skip-testing:SortTests/SlowProperties",
            "-only-testing:SortTests/SortProperties",
        ])
    }

    // A wrapper script is given the arguments as xcodebuild would be, its own flags among them.
    func test_testWithoutBuildArguments_forAWrapperScript_keepItsOwnFlags() {
        let wrapper = MuterConfiguration(
            executable: "/project/ci/run-tests.sh",
            arguments: [
                "--simulator-env", "SIMCTL_CHILD_LOG=1", "-destination", "platform=macOS", "-scheme", "App", "test",
            ],
            buildSystem: .xcodebuild
        )

        XCTAssertEqual(wrapper.testWithoutBuildArguments(with: "muter.xctestrun"), [
            "test-without-building",
            "-destination", "platform=macOS",
            "-xctestrun", "muter.xctestrun",
            "--simulator-env", "SIMCTL_CHILD_LOG=1",
        ])
    }

    // Beside the copy, so neither its fingerprint nor the build its runs test from sees it.
    // Its name ends in `.noindex`, so Spotlight skips it, whether the copy's name does or, as a test plan's copy made
    // by an older SwiftMutator, doesn't.
    func test_aWorkersDerivedData_isBesideTheMutatedProject() {
        for mutated in ["/path/App_mutated.noindex", "/path/App_mutated"].map(URL.init(fileURLWithPath:)) {
            XCTAssertEqual(
                MuterConfiguration.XcodeWorker.derivedData(ofWorker: 0, in: mutated),
                "/path/App_mutated.DerivedData.noindex"
            )
            XCTAssertEqual(
                MuterConfiguration.XcodeWorker.derivedData(ofWorker: 3, in: mutated),
                "/path/App_mutated_worker3.DerivedData.noindex"
            )
        }
    }
}
