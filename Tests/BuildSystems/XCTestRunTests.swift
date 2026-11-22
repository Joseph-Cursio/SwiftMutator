#if !os(Linux)
@testable import muterCore
import TestingExtensions
import XCTest

final class XCTestRunTests: MuterTestCase {
    func test_updateEnvironmentVariable() throws {
        let sut = try muterCore.XCTestRun(loadPlist(for: "project"))

        let actualPlist = sut.updateEnvironmentVariable(
            setting: "keyToBeSet"
        )

        let project = actualPlist["iOSProjectTests"] as? [String: AnyHashable]
        let environmentVariables = project?["EnvironmentVariables"] as? [String: AnyHashable]
        XCTAssertNotNil(environmentVariables?["keyToBeSet"])
        XCTAssertNotNil(environmentVariables?[isMuterRunningKey])
    }

    func test_updateEnvironmentVariable_forTestPlan() throws {
        let sut = try muterCore.XCTestRun(loadPlist(for: "projectWithTestPlan"))

        let actualPlist = sut.updateEnvironmentVariable(
            setting: "keyToBeSet"
        )

        let testConfigurations = actualPlist["TestConfigurations"] as? [AnyHashable]
        let testConfiguration = testConfigurations?.first as? [String: AnyHashable]
        let testTargets = testConfiguration?["TestTargets"] as? [AnyHashable]
        let testTarget = testTargets?.first as? [String: AnyHashable]
        let environmentVariables = testTarget?["EnvironmentVariables"] as? [String: AnyHashable]

        XCTAssertNotNil(environmentVariables?["keyToBeSet"])
        XCTAssertNotNil(environmentVariables?[isMuterRunningKey])
    }

    func test_updateEnvironmentVariable_createsEnvironmentVariablesWhenAbsent() {
        // A freshly generated .xctestrun target has no EnvironmentVariables dict. The var must still
        // be injected (regression: the old keys.contains guard skipped it → phantom 0% on simulator).
        let sut = muterCore.XCTestRun([
            "SomeTestTarget": ["BlueprintName": "SomeTestTarget"] as [String: AnyHashable]
        ])

        let actualPlist = sut.updateEnvironmentVariable(setting: "keyToBeSet")

        let target = actualPlist["SomeTestTarget"] as? [String: AnyHashable]
        let environmentVariables = target?["EnvironmentVariables"] as? [String: AnyHashable]
        XCTAssertEqual(environmentVariables?["keyToBeSet"], isMuterRunningValue)
        XCTAssertEqual(environmentVariables?[isMuterRunningKey], isMuterRunningValue)
    }

    func test_updateEnvironmentVariable_forTestPlan_createsEnvironmentVariablesWhenAbsent() {
        let sut = muterCore.XCTestRun([
            "TestConfigurations": [
                ["TestTargets": [["BlueprintName": "SomeTestTarget"] as [String: AnyHashable]]] as [String: AnyHashable]
            ],
        ])

        let actualPlist = sut.updateEnvironmentVariable(setting: "keyToBeSet")

        let testConfigurations = actualPlist["TestConfigurations"] as? [AnyHashable]
        let testConfiguration = testConfigurations?.first as? [String: AnyHashable]
        let testTargets = testConfiguration?["TestTargets"] as? [AnyHashable]
        let testTarget = testTargets?.first as? [String: AnyHashable]
        let environmentVariables = testTarget?["EnvironmentVariables"] as? [String: AnyHashable]

        XCTAssertEqual(environmentVariables?["keyToBeSet"], isMuterRunningValue)
        XCTAssertEqual(environmentVariables?[isMuterRunningKey], isMuterRunningValue)
    }

    // A run with no mutant on, as a worker's check run is, runs as SwiftMutator's runs do and switches nothing on.
    func test_updateEnvironmentVariable_withNoKey_setsOnlyIsMuterRunning() {
        let sut = muterCore.XCTestRun([
            "SomeTestTarget": [
                "EnvironmentVariables": ["OWN_VARIABLE": "1"] as [String: AnyHashable],
            ] as [String: AnyHashable],
        ])

        let actualPlist = sut.updateEnvironmentVariable(setting: nil)

        let target = actualPlist["SomeTestTarget"] as? [String: AnyHashable]
        XCTAssertEqual(
            target?["EnvironmentVariables"] as? [String: AnyHashable],
            ["OWN_VARIABLE": "1", isMuterRunningKey: isMuterRunningValue]
        )
    }

    // What an xcodebuild worker adds to its tests' environment goes in every test target's, in either format, over the
    // target's own variable of the same name; nothing added leaves the `.xctestrun` as it was.
    func test_addingEnvironment_setsItInEveryTestTarget_overTheTargetsOwn() throws {
        let own = ["TMPDIR": "/own/", "OWN_VARIABLE": "1"] as [String: AnyHashable]
        let legacy = muterCore.XCTestRun(["Tests": ["EnvironmentVariables": own] as [String: AnyHashable]])
        let testPlan = muterCore.XCTestRun.withTestTargets(["Tests": ["EnvironmentVariables": own]])
        let added = ["TMPDIR": "/worker/", "DIRHELPER_USER_DIR_SUFFIX": "sm-1"]
        let expected: [String: AnyHashable] = [
            "TMPDIR": "/worker/", "DIRHELPER_USER_DIR_SUFFIX": "sm-1", "OWN_VARIABLE": "1",
            isMuterRunningKey: isMuterRunningValue,
        ]

        let legacyTarget = legacy.adding(environment: added).updateEnvironmentVariable(setting: nil)["Tests"]
        let testPlanTargets = testPlan.adding(environment: added).updateEnvironmentVariable(setting: nil)
        let configuration = (testPlanTargets["TestConfigurations"] as? [AnyHashable])?.first
        let testPlanTarget = ((configuration as? [String: AnyHashable])?["TestTargets"] as? [AnyHashable])?.first

        for target in [legacyTarget, testPlanTarget] {
            let environment = (target as? [String: AnyHashable])?["EnvironmentVariables"]
            XCTAssertEqual(environment as? [String: AnyHashable], expected)
        }
        XCTAssertEqual(legacy.adding(environment: [:]), legacy)
    }

    // Parallel testing on for any test target makes a run from it clone its simulator, in either format.
    func test_parallelizes() throws {
        XCTAssertTrue(try muterCore.XCTestRun(loadPlist(for: "projectWithTestPlan")).parallelizes)
        XCTAssertFalse(try muterCore.XCTestRun(loadPlist(for: "project")).parallelizes)
        XCTAssertFalse(muterCore.XCTestRun().parallelizes)

        let legacy = muterCore.XCTestRun([
            "__xctestrun_metadata__": ["FormatVersion": 1] as [String: AnyHashable],
            "AppTests": ["ParallelizationEnabled": true] as [String: AnyHashable],
            "AppUITests": ["ParallelizationEnabled": false] as [String: AnyHashable],
        ])
        XCTAssertTrue(legacy.parallelizes)

        let serial = muterCore.XCTestRun([
            "TestConfigurations": [
                ["TestTargets": [["ParallelizationEnabled": false] as [String: AnyHashable]]] as [String: AnyHashable],
            ],
        ])
        XCTAssertFalse(serial.parallelizes)
    }

    func test_uiTestTargets_areNamedAsTestArgumentsNameThem() throws {
        let withUITests = try muterCore.XCTestRun(loadPlist(for: "projectWithTestPlan"))
        XCTAssertEqual(withUITests.uiTestTargets, ["iOSProjectUITests"])
        XCTAssertEqual(try muterCore.XCTestRun(loadPlist(for: "project")).uiTestTargets, [])
        XCTAssertEqual(muterCore.XCTestRun().uiTestTargets, [])
    }

    // A Swift package's test target runs in Xcode's `xctest` agent, as does a Mac app's target that the app doesn't
    // host; the app's hosted target and its UI test target don't.
    func test_hostedTestTargets_areThoseThatDontRunInXcodesXCTestAgent() throws {
        let package = try muterCore.XCTestRun(loadPlist(for: "macOSPackage"))
        XCTAssertEqual(package.testTargetNames, ["SumTests"])
        XCTAssertEqual(package.hostedTestTargets, [])

        let app = try muterCore.XCTestRun(loadPlist(for: "macOSApp"))
        XCTAssertEqual(app.testTargetNames, ["AppTests", "CoreTests", "AppUITests"])
        XCTAssertEqual(app.hostedTestTargets, ["AppTests", "AppUITests"])

        let iOSApp = try muterCore.XCTestRun(loadPlist(for: "project"))
        XCTAssertEqual(iOSApp.testTargetNames, ["iOSProjectTests"])
        XCTAssertEqual(iOSApp.hostedTestTargets, ["iOSProjectTests"])
    }

    // Read from a real `.xctestrun`: a package's tests can test on workers on a Mac; an app's only when the test
    // arguments leave out its hosted and UI test targets.
    func test_withMacWorkerFact_readsTheProjectsTestRun() throws {
        let package = try muterCore.XCTestRun(loadPlist(for: "macOSPackage"))
        let app = try muterCore.XCTestRun(loadPlist(for: "macOSApp"))
        let onAMac = { (arguments: [String]) in
            MuterConfiguration(
                executable: "/usr/bin/xcodebuild",
                arguments: ["-scheme", "App", "-destination", "platform=macOS"] + arguments + ["test"]
            )
        }

        XCTAssertTrue(onAMac([]).withMacWorkerFact(given: package).testsOnMacWorkers)
        XCTAssertFalse(onAMac([]).withMacWorkerFact(given: app).testsOnMacWorkers)
        XCTAssertFalse(onAMac(["-skip-testing:AppTests"]).withMacWorkerFact(given: app).testsOnMacWorkers)
        XCTAssertTrue(
            onAMac(["-skip-testing:AppTests", "-skip-testing", "AppUITests"]).withMacWorkerFact(given: app)
                .testsOnMacWorkers
        )
        XCTAssertTrue(onAMac(["-only-testing:CoreTests/SumTests"]).withMacWorkerFact(given: app).testsOnMacWorkers)
    }

    private func loadPlist(for fileName: String) throws -> [String: AnyHashable] {
        let data = try XCTUnwrap(
            FileManager.default
                .contents(atPath: fixturesDirectory + "/BuildForTesting/\(fileName).xctestrun")
        )

        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: AnyHashable] ?? [:]
    }

    func test_aMutantsMarker_isInEveryTestTargetsEnvironment() throws {
        let testRun = XCTestRun(["Tests": ["BlueprintName": "Tests"] as [String: AnyHashable]])

        let updated = testRun.updateEnvironmentVariable(setting: "mutant", activationMarker: "/marker")

        let target = try XCTUnwrap(updated["Tests"] as? [String: AnyHashable])
        let environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: AnyHashable])
        XCTAssertEqual(environment[activationMarkerKey], "/marker")
    }

    func test_aRunWithNoMutantOn_hasNoMarker() throws {
        let testRun = XCTestRun(["Tests": ["BlueprintName": "Tests"] as [String: AnyHashable]])

        let updated = testRun.updateEnvironmentVariable(setting: nil)

        let target = try XCTUnwrap(updated["Tests"] as? [String: AnyHashable])
        let environment = try XCTUnwrap(target["EnvironmentVariables"] as? [String: AnyHashable])
        XCTAssertNil(environment[activationMarkerKey])
    }
}
#endif
