@testable import muterCore
import XCTest

final class ConfigurationXcodeProjectParsingTests: MuterTestCase {

    func test_withDerivedDataPath() {
        let sut = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "-derivedDataPath",
                "foo/bar",
                "test",
            ]
        )

        XCTAssertEqual(
            sut.buildForTestingArguments,
            [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "-derivedDataPath",
                "foo/bar",
                "clean",
                "build-for-testing",
            ]
        )

        XCTAssertEqual(sut.derivedDataPath, "foo/bar")
    }

    // `test` would build and run every test before the build for testing, whatever else the arguments give. A value
    // that reads like an action is a value.
    func test_buildForTesting_neverRunsTheTests() {
        let cases: [(arguments: [String], expected: [String])] = [
            (["-scheme", "App", "-derivedDataPath", "DD", "test"], ["-scheme", "App", "-derivedDataPath", "DD"]),
            (["test", "-scheme", "App", "test"], ["-scheme", "App", "-derivedDataPath", "DerivedData"]),
            (["-scheme", "test", "clean", "test"], ["-scheme", "test", "clean", "-derivedDataPath", "DerivedData"]),
            (["-scheme", "App"], ["-scheme", "App", "-derivedDataPath", "DerivedData"]),
            // `build` would only build the project a second time.
            (["-scheme", "App", "build", "test"], ["-scheme", "App", "-derivedDataPath", "DerivedData"]),
        ]
        for (arguments, expected) in cases {
            let sut = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments)

            XCTAssertEqual(sut.buildForTestingArguments, expected + ["clean", "build-for-testing"], "\(arguments)")
        }
    }

    func test_withoutDerivedDataPath() {
        let sut = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "test",
            ]
        )

        XCTAssertEqual(
            sut.buildForTestingArguments,
            [
                "-project",
                "iOSApp.xcodeproj",
                "-scheme",
                "iOSApp",
                "-destination",
                "platform=iOS Simulator,name=iPhone SE (3rd generation)",
                "-derivedDataPath",
                "DerivedData",
                "clean",
                "build-for-testing",
            ]
        )

        XCTAssertEqual(sut.derivedDataPath, "DerivedData")
    }

    // Tests that run at once lose coverage counts unless each count is an atomic add.
    func test_coverageRun_makesTheCountersAtomic() {
        let sut = MuterConfiguration(executable: "/path/to/xcodebuild", arguments: ["-scheme", "App", "test"])

        XCTAssertEqual(sut.enableCoverageArguments, [
            "-scheme", "App", "test",
            "OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -instrprof-atomic-counter-update-all", "-enableCodeCoverage", "YES",
        ])
    }

    // xcodebuild takes the second of two settings with one name, so the flags join the project's own.
    func test_coverageRun_addsTheAtomicCountersToTheProjectsOwnSwiftFlags() {
        let sut = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-scheme", "App", "OTHER_SWIFT_FLAGS=-DMOCKS", "test"]
        )

        XCTAssertEqual(sut.enableCoverageArguments, [
            "-scheme", "App", "OTHER_SWIFT_FLAGS=-DMOCKS -Xllvm -instrprof-atomic-counter-update-all", "test",
            "-enableCodeCoverage", "YES",
        ])
    }

    // xcodebuild takes `-enableCodeCoverage` only once, so the coverage run's replaces the test command's, while the
    // build for testing keeps it: `NO` builds the `.xctestrun` every mutant runs from without coverage.
    func test_coverageRun_replacesTheTestCommandsOwnEnableCodeCoverage() {
        let sut = MuterConfiguration(
            executable: "/path/to/xcodebuild",
            arguments: ["-scheme", "App", "-enableCodeCoverage", "NO", "test"]
        )

        XCTAssertEqual(sut.enableCoverageArguments, [
            "-scheme", "App", "test",
            "OTHER_SWIFT_FLAGS=$(inherited) -Xllvm -instrprof-atomic-counter-update-all", "-enableCodeCoverage", "YES",
        ])
        XCTAssertEqual(sut.buildForTestingArguments, [
            "-scheme", "App", "-enableCodeCoverage", "NO", "-derivedDataPath", "DerivedData", "clean",
            "build-for-testing",
        ])
    }
}
