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

    // In seconds, written as an Int or a Double, like mutationTestTimeout. Unset, nothing has a limit.
    func test_parseBuildTimeout() throws {
        let swiftTest = "executable: /usr/bin/swift\narguments: [test]"
        let whole = try MuterConfiguration(from: Data("\(swiftTest)\nbuildTimeout: 900".utf8))
        let fraction = try MuterConfiguration(from: Data("\(swiftTest)\nbuildTimeout: 1.5".utf8))
        let json = try MuterConfiguration(
            from: Data(#"{"executable": "/usr/bin/swift", "arguments": ["test"], "buildTimeout": 600}"#.utf8)
        )
        let unset = try MuterConfiguration(from: Data(swiftTest.utf8))

        XCTAssertEqual(whole.buildTimeout, 900)
        XCTAssertEqual(fraction.buildTimeout, 1.5)
        XCTAssertEqual(json.buildTimeout, 600)
        XCTAssertNil(unset.buildTimeout)
        XCTAssertEqual(try MuterConfiguration(from: whole.asData), whole)
    }

    func test_workerCount_isOneWithoutTheKey_orWithoutASimulatorForXcodebuild() throws {
        let swift = try MuterConfiguration(from: Data("executable: /usr/bin/swift\narguments: [test]".utf8))
        let xcode = try MuterConfiguration(
            from: Data("executable: /usr/bin/xcodebuild\narguments: [test]\nmutationTestWorkers: 4".utf8)
        )
        let zero = MuterConfiguration(executable: "/usr/bin/swift", mutationTestWorkers: 0)

        XCTAssertEqual(swift.workerCount, 1)
        XCTAssertEqual(xcode.workerCount, 1)
        XCTAssertEqual(zero.workerCount, 1)
    }

    // Each worker gets a simulator of its own, like the one the first `-destination` names; one named by its id alone
    // is looked up when the run starts.
    func test_workerCount_forXcodebuild_isTheKeysOnASimulator() {
        for destination in [
            "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
            "platform=tvOS Simulator,name=Apple TV",
            "id=693E96A4-0E5B-4F3A-9E4C-2A39F5C8D1B7",
        ] {
            let configuration = xcodebuild(testingOn: destination, workers: 4)

            XCTAssertEqual(configuration.workerCount, 4, destination)
            XCTAssertNil(configuration.parallelWorkersUnsupportedReason, destination)
        }
    }

    func test_workerCount_forXcodebuild_isOneOffASimulator() {
        let mac = "a Mac app's test runs share its UserDefaults, saved state and container, so workers would see each "
            + "other's"
        let reasons = [
            "platform=macOS": mac,
            "platform=macOS,arch=x86_64": mac,
            "platform=macOS,variant=Mac Catalyst": mac,
            "platform=iOS,id=00008110-000A1C2E3F45801E": "an xcodebuild project tests more than one at once only on "
                + "a simulator, which `-destination platform=iOS,id=00008110-000A1C2E3F45801E` doesn't name",
            "generic/platform=iOS Simulator": "an xcodebuild project tests more than one at once only on a simulator, "
                + "which `-destination generic/platform=iOS Simulator` doesn't name",
        ]

        for (destination, reason) in reasons {
            let configuration = xcodebuild(testingOn: destination, workers: 4)

            XCTAssertEqual(configuration.workerCount, 1, destination)
            XCTAssertEqual(configuration.parallelWorkersUnsupportedReason, reason, destination)
        }
        XCTAssertEqual(
            MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"]).parallelWorkersUnsupportedReason,
            "an xcodebuild project tests more than one at once only on a simulator, and the test command gives no "
                + "`-destination`"
        )
    }

    func test_workerCount_forAnotherBuildSystem_isOne() {
        let other = MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"], mutationTestWorkers: 4)

        XCTAssertEqual(other.workerCount, 1)
        XCTAssertEqual(
            other.parallelWorkersUnsupportedReason,
            "only SwiftPM projects, and xcodebuild projects that test on a simulator, test more than one at once"
        )
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertNil(swift.parallelWorkersUnsupportedReason)
    }

    // A `-destination` with no value after it is no destination, rather than a crash.
    func test_firstDestination_isTheFirstsValue() {
        XCTAssertEqual(
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-destination", "platform=macOS", "-destination", "id=X", "test"]
            ).firstDestination,
            "platform=macOS"
        )
        XCTAssertNil(MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test", "-destination"])
            .firstDestination)
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

    func test_parseOneWorkerSimulator() throws {
        let xcodebuild = "executable: /usr/bin/xcodebuild\narguments: [test]"
        let always = try MuterConfiguration(from: Data("\(xcodebuild)\noneWorkerSimulator: true".utf8))
        let never = try MuterConfiguration(from: Data("\(xcodebuild)\noneWorkerSimulator: false".utf8))
        let automatic = try MuterConfiguration(from: Data(xcodebuild.utf8))

        XCTAssertEqual(always.oneWorkerSimulator, true)
        XCTAssertEqual(never.oneWorkerSimulator, false)
        XCTAssertNil(automatic.oneWorkerSimulator)
        XCTAssertTrue(try String(decoding: always.asData, as: UTF8.self).contains("oneWorkerSimulator: true"))
        XCTAssertFalse(try String(decoding: automatic.asData, as: UTF8.self).contains("oneWorkerSimulator"))
    }

    func test_oneWorkerSimulatorThatIsNotABoolean_failsToParse() {
        let yaml = "executable: /usr/bin/xcodebuild\narguments: [test]\noneWorkerSimulator: auto"

        XCTAssertThrowsError(try MuterConfiguration(from: Data(yaml.utf8)))
    }

    func test_parallelTestingArguments() {
        let cases: [(arguments: [String], expected: MuterConfiguration.ParallelTestingArguments)] = [
            (["test"], .unset),
            (["-parallel-testing-enabled", "YES", "test"], .tuned("-parallel-testing-enabled YES")),
            (["-parallel-testing-enabled", "yes", "test"], .tuned("-parallel-testing-enabled yes")),
            (["-parallel-testing-enabled", "NO", "test"], .off),
            (["-parallel-testing-worker-count", "3", "-parallel-testing-enabled", "no"], .off),
            (["-parallel-testing-worker-count", "3", "test"], .tuned("-parallel-testing-worker-count")),
            (["-maximum-parallel-testing-workers", "2", "test"], .tuned("-maximum-parallel-testing-workers")),
            (["-parallelize-tests-among-destinations", "test"], .tuned("-parallelize-tests-among-destinations")),
            (
                ["-maximum-parallel-testing-workers", "2", "-parallel-testing-enabled", "YES"],
                .tuned("-maximum-parallel-testing-workers")
            ),
            (["test", "-parallel-testing-enabled"], .unset),
        ]
        for (arguments, expected) in cases {
            let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: arguments)
            XCTAssertEqual(configuration.parallelTestingArguments, expected, "\(arguments)")
        }
    }

    func test_stopsAtFirstFailure_forSwiftPMUnlessSwitchedOff() {
        let swift = MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: true)
        XCTAssertTrue(swift.stopsAtFirstFailure)
        XCTAssertNil(swift.stopAtFirstFailureUnsupportedReason)

        // On by default: an unset key stops, and only an explicit false doesn't.
        XCTAssertTrue(MuterConfiguration(executable: "/usr/bin/swift").stopsAtFirstFailure)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/swift", stopAtFirstFailure: false).stopsAtFirstFailure)

        // xcodebuild runs the tests in a process SwiftMutator can't stop, whether the key is set or not.
        let xcode = MuterConfiguration(executable: "/usr/bin/xcodebuild", stopAtFirstFailure: true)
        XCTAssertFalse(xcode.stopsAtFirstFailure)
        XCTAssertNotNil(xcode.stopAtFirstFailureUnsupportedReason)
        XCTAssertFalse(MuterConfiguration(executable: "/usr/bin/xcodebuild").stopsAtFirstFailure)

        // A wrapper script counts only when the configuration says it runs `swift test`.
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh", stopAtFirstFailure: true).stopsAtFirstFailure)
        XCTAssertFalse(MuterConfiguration(executable: "/bin/sh").stopsAtFirstFailure)
        XCTAssertTrue(
            MuterConfiguration(executable: "/bin/sh", buildSystem: .swift, stopAtFirstFailure: true).stopsAtFirstFailure
        )
        XCTAssertTrue(MuterConfiguration(executable: "/bin/sh", buildSystem: .swift).stopsAtFirstFailure)
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

    // Each run of a mutant keeps its derived data beside the copy, not in ~/Library/Developer/Xcode/DerivedData. The
    // rest of the test command's arguments are still dropped.
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
            "-derivedDataPath", "/path/App_mutated_worker2.DerivedData",
            "-collect-test-diagnostics", "never",
            "-parallel-testing-enabled", "NO",
        ])
    }

    // Beside the copy, so neither its fingerprint nor the build its runs test from sees it.
    func test_aWorkersDerivedData_isBesideTheMutatedProject() {
        let mutated = URL(fileURLWithPath: "/path/App_mutated")

        XCTAssertEqual(
            MuterConfiguration.XcodeWorker.derivedData(ofWorker: 0, in: mutated),
            "/path/App_mutated.DerivedData"
        )
        XCTAssertEqual(
            MuterConfiguration.XcodeWorker.derivedData(ofWorker: 3, in: mutated),
            "/path/App_mutated_worker3.DerivedData"
        )
    }

    // Not a configuration key: neither the configuration file nor a results file's header holds it.
    func test_xcodeWorker_isNeverEncoded() throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let withWorker = configuration.forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: true
        ))

        XCTAssertEqual(try withWorker.asData, try configuration.asData)
        XCTAssertEqual(try MuterConfiguration(from: withWorker.asData), configuration)
    }

    func test_asData_writesStopAtFirstFailureOnlyWhenSet() throws {
        // Left out while unset, so `init` and the JSON-to-YAML migration write the same files as before.
        let unset = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertFalse(try String(decoding: unset.asData, as: UTF8.self).contains("stopAtFirstFailure"))

        for value in [true, false] {
            let configuration = MuterConfiguration(
                executable: "/usr/bin/swift",
                arguments: ["test"],
                stopAtFirstFailure: value
            )

            XCTAssertTrue(
                try String(decoding: configuration.asData, as: UTF8.self).contains("stopAtFirstFailure: \(value)")
            )
            XCTAssertEqual(try MuterConfiguration(from: configuration.asData), configuration)
        }
    }

    func test_configurationWithEveryFieldSet_leavesNoFieldAtItsDefault() {
        // A field added to MuterConfiguration fails this until the helper in Fixtures.swift sets it, which makes
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

    func test_forXcodeWorker_keepsEveryOtherField() throws {
        let configuration = configurationWithEveryFieldSet()
        let worker = try XCTUnwrap(configuration.xcodeWorker)
        let other = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/path/App_mutated.DerivedData",
            testDiagnosticsOff: false
        )

        XCTAssertEqual(configuration.forXcodeWorker(other).xcodeWorker, other)
        XCTAssertEqual(configuration.forXcodeWorker(other).forXcodeWorker(worker), configuration)
    }

    func test_withUnreliableFailedTestLines_keepsEveryOtherField() {
        XCTAssertEqual(
            configurationWithEveryFieldSet(failedTestLinesAreReliable: true).withUnreliableFailedTestLines(),
            configurationWithEveryFieldSet(failedTestLinesAreReliable: false)
        )
    }

    /// An xcodebuild test command on `destination`, with `workers` workers.
    private func xcodebuild(testingOn destination: String, workers: Int) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: workers
        )
    }
}
