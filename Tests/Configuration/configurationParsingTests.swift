@testable import muterCore
import XCTest

final class ConfigurationParsingTests: MuterTestCase {
    func test_parse() {
        let configuration = MuterConfiguration.fromFixture(at: "\(fixturesDirectory)/muter.conf.withoutExcludeList.yml")

        XCTAssertEqual(configuration?.excludeFileList, [])
        XCTAssertEqual(configuration?.testCommandExecutable, "/usr/bin/xcodebuild")
        XCTAssertEqual(configuration?.testCommandArguments, [
            "-project",
            "ExampleApp.xcodeproj",
            "-scheme",
            "ExampleApp",
            "-sdk",
            "iphonesimulator",
            "-destination",
            "platform=iOS Simulator,name=iPhone SE (3rd generation)",
            "test",
        ])
    }

    func test_parseExcludeList() {
        let configuration = MuterConfiguration.fromFixture(at: "\(fixturesDirectory)/muter.conf.withExcludeList.yml")

        XCTAssertEqual(configuration?.excludeFileList, ["ExampleApp"])
    }

    func test_buildSystem_defaultsToExecutableBasename() throws {
        let yaml = """
        executable: /usr/bin/xcodebuild
        arguments: [test]
        """
        let configuration = try MuterConfiguration(from: Data(yaml.utf8))

        XCTAssertNil(configuration.explicitBuildSystem)
        XCTAssertEqual(configuration.buildSystem, .xcodebuild)
    }

    func test_explicitBuildSystem_overridesWrapperExecutableName() throws {
        // A wrapper executable whose filename isn't `xcodebuild` would otherwise resolve to `.unknown`;
        // the explicit `buildSystem:` key forces the correct build system.
        let yaml = """
        executable: ./.muter-bin/wrapper.sh
        arguments: [test]
        buildSystem: xcodebuild
        """
        let configuration = try MuterConfiguration(from: Data(yaml.utf8))

        XCTAssertEqual(configuration.explicitBuildSystem, .xcodebuild)
        XCTAssertEqual(configuration.buildSystem, .xcodebuild)
    }

    func test_parseMutationTestWorkers() throws {
        let yaml = """
        executable: /usr/bin/swift
        arguments: [test]
        mutationTestWorkers: 4
        mutationTestTimeout: 30
        """
        let configuration = try MuterConfiguration(from: Data(yaml.utf8))

        XCTAssertEqual(configuration.mutationTestWorkers, 4)
        XCTAssertEqual(configuration.workerCount, 4)
        XCTAssertEqual(configuration.testSuiteTimeout, 30)
    }

    func test_workerCount_isOneWithoutTheKeyOrOutsideSwiftPM() throws {
        let swift = try MuterConfiguration(from: Data("executable: /usr/bin/swift\narguments: [test]".utf8))
        let xcode = try MuterConfiguration(
            from: Data("executable: /usr/bin/xcodebuild\narguments: [test]\nmutationTestWorkers: 4".utf8)
        )
        let zero = MuterConfiguration(executable: "/usr/bin/swift", mutationTestWorkers: 0)

        XCTAssertEqual(swift.workerCount, 1)
        XCTAssertEqual(xcode.workerCount, 1)
        XCTAssertEqual(zero.workerCount, 1)
    }

    func test_withDefaultTestSuiteTimeout_fillsInOnlyAMissingTimeout() {
        XCTAssertEqual(MuterConfiguration().withDefaultTestSuiteTimeout(12).testSuiteTimeout, 12)
        XCTAssertEqual(
            MuterConfiguration(testSuiteTimeOut: 5, mutationTestWorkers: 3).withDefaultTestSuiteTimeout(12),
            MuterConfiguration(testSuiteTimeOut: 5, mutationTestWorkers: 3)
        )
    }

    func test_configurationWithEveryFieldSet_leavesNoFieldAtItsDefault() {
        // A field added to MuterConfiguration fails this until the helper below sets it, which makes
        // the copy tests that follow cover the new field too.
        let fields = Mirror(reflecting: configurationWithEveryFieldSet()).children
        let defaults = Mirror(reflecting: MuterConfiguration()).children
        for (field, defaultField) in zip(fields, defaults) {
            XCTAssertNotEqual(
                "\(field.value)",
                "\(defaultField.value)",
                "\(field.label ?? "a field") is at its default"
            )
        }
    }

    func test_withExecutable_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet().withExecutable("/opt/homebrew/bin/swift"),
            configurationWithEveryFieldSet(executable: "/opt/homebrew/bin/swift")
        )
    }

    func test_withDefaultTestSuiteTimeout_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(timeout: nil).withDefaultTestSuiteTimeout(12),
            configurationWithEveryFieldSet(timeout: 12)
        )
    }

    /// No field is left at its default, so a copy that drops one no longer equals this.
    private func configurationWithEveryFieldSet(
        executable: String = "/usr/bin/swift",
        timeout: Double? = 30
    ) -> MuterConfiguration {
        MuterConfiguration(
            executable: executable,
            arguments: ["test"],
            excludeList: ["Generated"],
            excludeCallList: ["print"],
            coverageThreshold: 80,
            testSuiteTimeOut: timeout,
            buildSystem: .swift,
            mutationTestWorkers: 4
        )
    }
}
