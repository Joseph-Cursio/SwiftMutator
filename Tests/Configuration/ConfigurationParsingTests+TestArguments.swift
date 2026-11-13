@testable import muterCore
import XCTest

extension ConfigurationParsingTests {
    func test_parallelTestingArguments() {
        let cases: [(arguments: [String], expected: MuterConfiguration.ParallelTestingArguments)] = [
            (["test"], .unset),
            (["-parallel-testing-enabled", "YES", "test"], .enabled),
            (["-parallel-testing-enabled", "yes", "test"], .enabled),
            (["-parallel-testing-enabled", "NO", "test"], .disabled),
            (["-parallel-testing-worker-count", "3", "-parallel-testing-enabled", "no"], .disabled),
            // Options that only tune it leave it to the scheme or the test plan.
            (["-parallel-testing-worker-count", "3", "test"], .unset),
            (["-maximum-parallel-testing-workers", "2", "test"], .unset),
            (["-parallelize-tests-among-destinations", "test"], .unset),
            (["-maximum-parallel-testing-workers", "2", "-parallel-testing-enabled", "YES"], .enabled),
            (["test", "-parallel-testing-enabled"], .unset),
        ]
        for (arguments, expected) in cases {
            let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments)
            XCTAssertEqual(configuration.parallelTestingArguments, expected, "\(arguments)")
        }
    }

    func test_stopsAtFirstFailure_forSwiftPMUnlessSwitchedOff() {
        let swift = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: .enabled)
        XCTAssertTrue(swift.stopsAtFirstFailure)
        XCTAssertNil(swift.stopAtFirstFailureUnsupportedReason)

        // On by default: an unset key stops, and only an explicit false doesn't.
        XCTAssertTrue(MuterConfiguration(executable: "/usr/bin/swift").stopsAtFirstFailure)
        XCTAssertFalse(
            MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: .disabled).stopsAtFirstFailure
        )

        // xcodebuild runs the tests in a process SwiftMutator can't stop, whether the key is set or not.
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", stopAtFirstFailure: .enabled)
        XCTAssertFalse(xcode.stopsAtFirstFailure)
        XCTAssertNotNil(xcode.stopAtFirstFailureUnsupportedReason)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/xcodebuild").stopsAtFirstFailure)

        // A wrapper script counts only when the configuration says it runs `swift test`.
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh", stopAtFirstFailure: .enabled).stopsAtFirstFailure)
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh").stopsAtFirstFailure)
        XCTAssertTrue(
            MuterConfiguration(executable: "/bin/sh", buildSystem: .swift, stopAtFirstFailure: .enabled)
                .stopsAtFirstFailure
        )
        XCTAssertTrue(MuterConfiguration(executable: "/bin/sh", buildSystem: .swift).stopsAtFirstFailure)
    }

    func test_stopsAtFirstFailure_isOffWhenFailingTestsAreRetried() {
        for arguments in [["test", "--repeat-until", "pass"], ["test", "--repeat-until=pass"]] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: arguments,
                stopAtFirstFailure: .enabled
            )

            XCTAssertFalse(configuration.stopsAtFirstFailure, "\(arguments)")
            XCTAssertNotNil(configuration.stopAtFirstFailureUnsupportedReason, "\(arguments)")
        }
    }

    // A passing baseline printed a line shaped like a failed test, so such a line can't stop a run.
    func test_stopsAtFirstFailure_isOffOnceFailedTestLinesAreUnreliable() {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: .enabled)

        XCTAssertTrue(configuration.failedTestLinesAreReliable)
        XCTAssertTrue(configuration.stopsAtFirstFailure)
        XCTAssertFalse(configuration.withUnreliableFailedTestLines().stopsAtFirstFailure)
    }

    // Swift Testing then prints no line for each test that starts or passes; a verbosity the arguments set is kept.
    func test_testWithoutBuildArguments_forSwiftPM_skipTheBuild_quietly_unlessTheArgumentsSetAVerbosity() {
        let quiet = { (arguments: [String]) in
            MuterConfiguration(executable: "/usr/bin/swift", arguments: arguments).testWithoutBuildArguments(with: "")
        }

        XCTAssertEqual(quiet(["test", "--filter", "Core"]), ["test", "--filter", "Core", "--skip-build", "--quiet"])
        for verbosity in ["-q", "--quiet", "-v", "--verbose", "--very-verbose", "--vv"] {
            XCTAssertEqual(quiet(["test", verbosity]), ["test", verbosity, "--skip-build"], verbosity)
        }
        // xcodebuild has its own arguments for a run without building.
        let xcode = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test", "-destination", "platform=macOS"]
        )
        XCTAssertFalse(xcode.testWithoutBuildArguments(with: "run.xctestrun").contains("--quiet"))
    }
}
