@testable import muterCore
import TestingExtensions
import XCTest

/// What an xcodebuild worker's runs test from: its own `.xctestrun`, which a mutant is switched on in, and its own
/// arguments.
final class MutationTestingDelegateXcodeWorkerTests: MuterTestCase {
    private var outputFolder = ""
    private var outputFolderURL: URL { URL(fileURLWithPath: outputFolder) }

    private let sut = MutationTestingDelegate()

    override func setUpWithError() throws {
        try super.setUpWithError()

        outputFolder = try makeTemporaryDirectory()
        // Test logs are written to the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = outputFolder
    }

    // Each xcodebuild worker tests from a file of its own, beside `muter.xctestrun`, which is left alone.
    func test_switchOn_writesTheNamedTestRun() async throws {
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))
        let testRun = XCTestRun(["Tests": ["BlueprintName": "Tests"] as [String: AnyHashable]])

        try await sut.switchOn(schemata: schemata, for: testRun, at: outputFolderURL, named: "muter-worker2.xctestrun")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outputFolder), ["muter-worker2.xctestrun"])
        XCTAssertEqual(
            try environmentVariables(in: "muter-worker2.xctestrun"),
            [
                schemata.id: isMuterRunningValue,
                activationMarkerKey: ActivationMarker(
                    of: schemata, forWorkerIn: outputFolderURL, testRunFile: "muter-worker2.xctestrun"
                ).path,
                isMuterRunningKey: isMuterRunningValue,
            ]
        )
    }

    // A worker's run with no mutant on, such as the one that checks it, still runs as SwiftMutator's runs do.
    func test_switchOnNull_setsOnlyIsMuterRunning() async throws {
        let testRun = XCTestRun(["Tests": ["BlueprintName": "Tests"] as [String: AnyHashable]])

        try await sut.switchOn(schemata: .null, for: testRun, at: outputFolderURL, named: "muter-worker1.xctestrun")

        XCTAssertEqual(
            try environmentVariables(in: "muter-worker1.xctestrun"),
            [isMuterRunningKey: isMuterRunningValue]
        )
    }

    func test_eachXcodebuildWorker_hasATestRunFileOfItsOwn_atTheProjectsRoot() {
        XCTAssertEqual(
            (0...2).map(MutationTestingDelegate.testRunFileName(ofWorker:)),
            ["muter.xctestrun", "muter-worker1.xctestrun", "muter-worker2.xctestrun"]
        )
        XCTAssertTrue(MutationTestingDelegate.isWorkerTestRunFileName("muter-worker12.xctestrun"))
        for name in [
            "muter.xctestrun", "muter-worker.xctestrun", "muter-worker2.xctestrun.bak", "muter-workerX.xctestrun",
            "muter-worker+1.xctestrun", "my-muter-worker2.xctestrun",
        ] {
            XCTAssertFalse(MutationTestingDelegate.isWorkerTestRunFileName(name), name)
        }
    }

    // On an xcodebuild worker, it is the run that checks the worker: from the worker's own test run, on its own
    // destination, with its own derived data, emptied first, as a mutant's run on it would be.
    func test_runningTestsWithoutBuilding_onAnXcodebuildWorker_usesTheWorkersArgumentsAndNoTimeLimit() async throws {
        let configuration = MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: ["-destination", "platform=iOS Simulator,name=iPhone 17", "-only-testing", "Tests", "test"],
            testSuiteTimeOut: 5
        )
        .forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/path/App_mutated_worker1.DerivedData",
            destination: "platform=iOS Simulator,id=SIM-1",
            parallelTestingOff: true,
            testDiagnosticsOff: true
        ))

        _ = await sut.runTestsWithoutBuilding(
            using: configuration, timeLimit: nil, savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(process.arguments, [
            "test-without-building",
            "-destination",
            "platform=iOS Simulator,id=SIM-1",
            "-xctestrun",
            "muter-worker1.xctestrun",
            "-derivedDataPath",
            "/path/App_mutated_worker1.DerivedData",
            "-collect-test-diagnostics",
            "never",
            "-parallel-testing-enabled",
            "NO",
        ])
        XCTAssertEqual(fileManager.paths, ["/path/App_mutated_worker1.DerivedData"])
        XCTAssertFalse(testingTimeOutExecutor.withTimeLimitCalled)
    }

    /// The `EnvironmentVariables` of the `Tests` target in the `.xctestrun` file `name` in the output folder.
    private func environmentVariables(in name: String) throws -> [String: String] {
        let data = try Data(contentsOf: outputFolderURL.appendingPathComponent(name))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let target = try XCTUnwrap(plist["Tests"] as? [String: Any])
        return try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
    }

    // Repeated mutants share an ID, and two workers can test them at once from one folder.
    func test_twoWorkersMarkersDiffer_forOneMutant() throws {
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        XCTAssertNotEqual(
            ActivationMarker(of: schemata, forWorkerIn: outputFolderURL, testRunFile: "muter.xctestrun"),
            ActivationMarker(of: schemata, forWorkerIn: outputFolderURL, testRunFile: "muter-worker1.xctestrun")
        )
    }
}
