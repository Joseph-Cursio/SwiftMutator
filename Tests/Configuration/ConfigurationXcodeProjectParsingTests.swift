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
                "test",
                "clean",
                "build-for-testing",
            ]
        )

        XCTAssertEqual(sut.derivedDataPath, "foo/bar")
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
}
