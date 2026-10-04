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

    func test_parseStopAtFirstFailure() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let switchedOn = try MuterConfiguration(from: Data("\(swiftTest)\nstopAtFirstFailure: true".utf8))
        let switchedOff = try MuterConfiguration(from: Data("\(swiftTest)\nstopAtFirstFailure: false".utf8))
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))

        XCTAssertEqual(switchedOn.stopAtFirstFailure, true)
        XCTAssertEqual(switchedOff.stopAtFirstFailure, false)
        XCTAssertNil(unset.stopAtFirstFailure)
    }

    func test_stopAtFirstFailureThatIsNotABoolean_failsToParse() {
        // An error, as for mutationTestWorkers, rather than read as unset: a typo would otherwise leave
        // every run going to its end without a word.
        let yaml = "executable: /usr/bin/swift\narguments: [test]\nstopAtFirstFailure: sometimes"

        XCTAssertThrowsError(try MuterConfiguration(from: Data(yaml.utf8)))
    }

    func test_stopsAtFirstFailure_onlyForSwiftPMWhenSwitchedOn() {
        let swift = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: true)
        XCTAssertTrue(swift.stopsAtFirstFailure)
        XCTAssertNil(swift.stopAtFirstFailureUnsupportedReason)

        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/swift").stopsAtFirstFailure)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: false).stopsAtFirstFailure)

        // xcodebuild runs the tests in a process SwiftMutator can't stop.
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", stopAtFirstFailure: true)
        XCTAssertFalse(xcode.stopsAtFirstFailure)
        XCTAssertNotNil(xcode.stopAtFirstFailureUnsupportedReason)

        // A wrapper script counts only when the configuration says it runs `swift test`.
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh", stopAtFirstFailure: true).stopsAtFirstFailure)
        XCTAssertTrue(
            MuterConfiguration(executable: "/bin/sh", buildSystem: .swift, stopAtFirstFailure: true).stopsAtFirstFailure
        )
    }

    func test_stopsAtFirstFailure_isOffWhenFailingTestsAreRetried() {
        for arguments in [["test", "--repeat-until", "pass"], ["test", "--repeat-until=pass"]] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: arguments,
                stopAtFirstFailure: true
            )

            XCTAssertFalse(configuration.stopsAtFirstFailure, "\(arguments)")
            XCTAssertNotNil(configuration.stopAtFirstFailureUnsupportedReason, "\(arguments)")
        }
    }

    // A passing baseline printed a line shaped like a failed test, so such a line can't stop a run.
    func test_stopsAtFirstFailure_isOffOnceFailedTestLinesAreUnreliable() {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: true)

        XCTAssertTrue(configuration.failedTestLinesAreReliable)
        XCTAssertTrue(configuration.stopsAtFirstFailure)
        XCTAssertFalse(configuration.withUnreliableFailedTestLines().stopsAtFirstFailure)
    }

    func test_asData_writesStopAtFirstFailureOnlyWhenSet() throws {
        // Left out while unset, so `init` and the JSON-to-YAML migration write the same files as before.
        let unset = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertFalse(String(decoding: unset.asData, as: UTF8.self).contains("stopAtFirstFailure"))

        for value in [true, false] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: ["test"],
                stopAtFirstFailure: value
            )

            XCTAssertTrue(String(decoding: configuration.asData, as: UTF8.self).contains("stopAtFirstFailure: \(value)"))
            XCTAssertEqual(try MuterConfiguration(from: configuration.asData), configuration)
        }
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

    func test_withUnreliableFailedTestLines_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(failedTestLinesAreReliable: true).withUnreliableFailedTestLines(),
            configurationWithEveryFieldSet(failedTestLinesAreReliable: false)
        )
    }

    /// No field is left at its default, so a copy that drops one no longer equals this.
    private func configurationWithEveryFieldSet(
        executable: String = "/usr/bin/swift",
        timeout: Double? = 30,
        failedTestLinesAreReliable: Bool = false
    ) -> MuterConfiguration {
        let configuration = MuterConfiguration(
            executable: executable,
            arguments: ["test"],
            excludeList: ["Generated"],
            excludeCallList: ["print"],
            coverageThreshold: 80,
            testSuiteTimeOut: timeout,
            buildSystem: .swift,
            mutationTestWorkers: 4,
            stopAtFirstFailure: false
        )
        return failedTestLinesAreReliable ? configuration : configuration.withUnreliableFailedTestLines()
    }
}
