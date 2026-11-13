@testable import muterCore
import XCTest

extension ConfigurationParsingTests {
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

    // On one processor, as every test's world has it, unless it says otherwise.
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

    // Half the processors, as each worker's tests already run in parallel, and at most 4.
    func test_theDefaultWorkerCount_forSwiftPM_goesByTheProcessors() {
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let counts = [1: 1, 2: 1, 3: 1, 4: 2, 6: 3, 8: 4, 18: 4, 64: 4]

        for (processors, count) in counts {
            current.processorCount = processors
            XCTAssertEqual(swift.defaultWorkerCount, count, "\(processors)")
            XCTAssertEqual(swift.workerCount, count, "\(processors)")
        }
    }

    func test_theDefaultWorkerCount_isOneForEveryOtherBuildSystem() {
        current.processorCount = 18
        let others = [
            MuterConfiguration(executable: "/usr/bin/make", arguments: ["test"]),
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild", arguments: ["-destination", "platform=macOS", "test"]
            ),
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "test"]
            ),
        ]

        for other in others {
            XCTAssertEqual(other.defaultWorkerCount, 1, other.testCommandExecutable)
            XCTAssertEqual(other.workerCount(testing: 500), 1, other.testCommandExecutable)
        }
    }

    // A clone costs about a baseline build, so the default adds a worker only for enough mutants to pay it back.
    func test_workerCountTesting_goesByTheMutants_unlessTheCountIsSet() {
        current.processorCount = 18
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        let asked = swift.overriding(workers: 8, timeout: nil)

        let byDefault = [0: 0, 1: 1, 49: 1, 50: 2, 99: 2, 100: 3, 150: 4, 5_000: 4]
        for (mutants, count) in byDefault {
            XCTAssertEqual(swift.workerCount(testing: mutants), count, "\(mutants)")
        }
        let whenSet = [0: 0, 1: 1, 3: 3, 49: 8, 5_000: 8]
        for (mutants, count) in whenSet {
            XCTAssertEqual(asked.workerCount(testing: mutants), count, "\(mutants)")
        }
    }

    // Workers that share a build need no clone, so only the mutants and the count limit them.
    func test_workerCountTesting_sharingABuild_needsNoMutantsToPayItBack() {
        current.processorCount = 18
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])

        let sharing = [0: 0, 1: 1, 3: 3, 4: 4, 49: 4, 5_000: 4]
        for (mutants, count) in sharing {
            XCTAssertEqual(swift.workerCount(testing: mutants, sharingBuild: true), count, "\(mutants)")
        }
        XCTAssertEqual(swift.overriding(workers: 2, timeout: nil).workerCount(testing: 49, sharingBuild: true), 2)
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

    /// An xcodebuild test command on `destination`, with `workers` workers.
    func xcodebuild(testingOn destination: String, workers: Int) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: workers
        )
    }
}
