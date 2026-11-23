@testable import muterCore
import XCTest

/// The project's `.xctestrun`, not XCTest's class of the same name.
private typealias ProjectTestRun = muterCore.XCTestRun

/// An xcodebuild run on a Mac whose tests run in Xcode's `xctest` agent, which tests several mutants at once, each
/// worker on the Mac, as a SwiftPM run's do.
extension ConfigurationParsingTests {
    private static let macReason = "a Mac app's test runs share its UserDefaults, saved state and container, so "
        + "workers would see each other's"

    // Only `platform=macOS`, with or without an `arch=`, whose tests are all in the agent: not Mac Catalyst, which
    // nothing measured, nor a simulator, whose workers get simulators.
    func test_testsOnMacWorkers_onlyOnAMac_notMacCatalyst() {
        let destinations = [
            "platform=macOS": true,
            "platform=macOS,arch=arm64": true,
            "platform=OS X,arch=x86_64": false,
            "platform=macOS,variant=Mac Catalyst": false,
            "platform=macOS,arch=arm64,variant=Mac Catalyst": false,
            "platform=iOS Simulator,name=iPhone 17": false,
            "generic/platform=macOS": false,
        ]

        for (destination, expected) in destinations {
            let configuration = mac(destination).withMacWorkerFact(given: .unhostedFixture)

            XCTAssertEqual(configuration.testsOnMacWorkers, expected, destination)
        }
        XCTAssertTrue(MuterConfiguration.namesMacCatalyst("platform=macOS, variant = Mac Catalyst"))
        XCTAssertFalse(MuterConfiguration.namesMacCatalyst("platform=iOS Simulator,variant=X"))
        XCTAssertFalse(mac("platform=macOS").testsOnMacWorkers, "without the fact")
        let swift = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        XCTAssertFalse(swift.withMacWorkerFact(given: .unhostedFixture).testsOnMacWorkers)
    }

    // A target an app hosts, a UI test target, or one with no `TestHostPath` keeps the run on one worker, unless the
    // test arguments leave it out; an `.xctestrun` with no target the run tests shows nothing.
    func test_withMacWorkerFact_countsOnlyTheTargetsTheRunTests() {
        let core: [String: AnyHashable] = ["TestHostPath": ProjectTestRun.macAgentPath]
        let app: [String: AnyHashable] = ["TestHostPath": ProjectTestRun.macAppPath, "IsAppHostedTestBundle": true]
        let agentButHosted: [String: AnyHashable] = [
            "TestHostPath": ProjectTestRun.macAgentPath, "IsAppHostedTestBundle": true,
        ]
        let uiTests: [String: AnyHashable] = ["TestHostPath": ProjectTestRun.macAgentPath, "IsUITestBundle": true]
        let coreAndApp = ProjectTestRun.withTestTargets(["CoreTests": core, "AppTests": app])

        assertMacWorkers(.withTestTargets(["CoreTests": core]), [], true)
        assertMacWorkers(coreAndApp, [], false)
        assertMacWorkers(.withTestTargets(["CoreTests": core, "AppTests": agentButHosted]), [], false)
        assertMacWorkers(.withTestTargets(["CoreTests": core, "AppUITests": uiTests]), [], false)
        assertMacWorkers(.withTestTargets(["CoreTests": [:]]), [], false)
        assertMacWorkers(coreAndApp, ["-skip-testing:AppTests"], true)
        assertMacWorkers(coreAndApp, ["-skip-testing:AppTests/LoginTests"], false)
        assertMacWorkers(coreAndApp, ["-only-testing:CoreTests"], true)
        assertMacWorkers(coreAndApp, ["-only-testing", "@tests.txt"], false)
        assertMacWorkers(.withTestTargets(["CoreTests": core]), ["-skip-testing:CoreTests"], false)
        assertMacWorkers(ProjectTestRun(), [], false)
        // The legacy format, whose metadata is no test target.
        let legacy = ProjectTestRun([
            "__xctestrun_metadata__": ["FormatVersion": 1] as [String: AnyHashable],
            "CoreTests": ["BlueprintName": "CoreTests", "TestHostPath": ProjectTestRun.macAgentPath]
                as [String: AnyHashable],
        ])
        assertMacWorkers(legacy, [], true)
    }

    // As SwiftPM's: half the processors, at most 4, whatever the memory, as they need no simulator.
    func test_theDefaultWorkerCount_onMacWorkers_goesByTheProcessors() {
        current.physicalMemory = 8 << 30
        let configuration = mac("platform=macOS").withMacWorkerFact(given: .unhostedFixture)
        let counts = [1: 1, 2: 1, 3: 1, 4: 2, 6: 3, 8: 4, 18: 4, 64: 4]

        for (processors, count) in counts {
            current.processorCount = processors
            XCTAssertEqual(configuration.defaultWorkerCount, count, "\(processors)")
            XCTAssertEqual(configuration.workerCount, count, "\(processors)")
        }
        XCTAssertNil(configuration.parallelWorkersUnsupportedReason)
        XCTAssertEqual(configuration.simulatorWorkersUnsupportedReason, Self.macReason)
        current.processorCount = 18
        XCTAssertEqual(
            mac("platform=macOS", oneWorkerSimulator: .disabled).withMacWorkerFact(given: .unhostedFixture)
                .defaultWorkerCount,
            4,
            "makes no simulator anyway"
        )
    }

    // They share one build and make no simulator, so there is nothing for mutants to pay back: as many as there are,
    // up to the count; an asked count is kept.
    func test_workerCountTesting_onMacWorkers_needsNoMutantsToPayItBack() {
        current.processorCount = 18
        let byDefault = mac("platform=macOS").withMacWorkerFact(given: .unhostedFixture)
        let asked = mac("platform=macOS", workers: 6).withMacWorkerFact(given: .unhostedFixture)

        for (mutants, count) in [0: 0, 1: 1, 3: 3, 4: 4, 49: 4, 5_000: 4] {
            XCTAssertEqual(byDefault.workerCount(testing: mutants), count, "\(mutants)")
        }
        for (mutants, count) in [1: 1, 3: 3, 6: 6, 49: 6] {
            XCTAssertEqual(asked.workerCount(testing: mutants), count, "\(mutants)")
        }
        XCTAssertEqual(asked.workerCount, 6)
    }

    // A Mac app's tests, UI tests and Mac Catalyst test one mutant at a time, saying today's reason.
    func test_aMacAppsTests_uiTests_andMacCatalyst_stayAtOneWorker() {
        current.processorCount = 18
        let hosted = ProjectTestRun.withTestTargets([
            "AppTests": ["TestHostPath": ProjectTestRun.macAppPath, "IsAppHostedTestBundle": true],
        ])
        let uiTests = ProjectTestRun.withTestTargets([
            "AppUITests": ["TestHostPath": "__TESTROOT__/Debug/AppUITests-Runner.app", "IsUITestBundle": true],
        ])
        let configurations = [
            mac("platform=macOS", workers: 4).withMacWorkerFact(given: hosted),
            mac("platform=macOS").withMacWorkerFact(given: hosted),
            mac("platform=macOS", workers: 4).withMacWorkerFact(given: uiTests),
            mac("platform=macOS,variant=Mac Catalyst", workers: 4).withMacWorkerFact(given: .unhostedFixture),
            mac("platform=macOS,variant=Mac Catalyst").withMacWorkerFact(given: .unhostedFixture),
        ]

        for configuration in configurations {
            XCTAssertEqual(configuration.workerCount, 1, "\(configuration.testCommandArguments)")
            XCTAssertEqual(configuration.workerCount(testing: 500), 1, "\(configuration.testCommandArguments)")
            XCTAssertEqual(
                configuration.parallelWorkersUnsupportedReason, Self.macReason, "\(configuration.testCommandArguments)"
            )
        }
    }

    /// Asserts whether workers test on a Mac, given `xctestrun` and the test command's `arguments`.
    private func assertMacWorkers(
        _ xctestrun: ProjectTestRun,
        _ arguments: [String],
        _ expected: Bool,
        line: UInt = #line
    ) {
        let configuration = mac("platform=macOS", arguments: arguments).withMacWorkerFact(given: xctestrun)

        XCTAssertEqual(configuration.testsRunUnhosted, expected, "\(arguments)", line: line)
        XCTAssertEqual(configuration.testsOnMacWorkers, expected, "\(arguments)", line: line)
    }

    /// An xcodebuild test command on `destination`, with `arguments` before `test`.
    private func mac(
        _ destination: String,
        arguments: [String] = [],
        workers: Int? = nil,
        oneWorkerSimulator: ConfigurationSwitch = .unset
    ) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination] + arguments + ["test"],
            mutationTestWorkers: workers,
            oneWorkerSimulator: oneWorkerSimulator
        )
    }
}
