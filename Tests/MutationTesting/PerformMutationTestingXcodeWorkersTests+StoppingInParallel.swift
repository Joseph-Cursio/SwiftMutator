@testable import muterCore
import TestingExtensions
import XCTest

/// Which xcodebuild runs' mutants stop when the test command tests in parallel, and when it skips a UI test target.
extension PerformMutationTestingXcodeWorkersTests {
    // Each worker's simulator of its own tests one test at a time, whatever the test command says.
    func test_mutantsOnTheWorkersSimulators_stop_thoughTheTestCommandTestsInParallel() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "-parallel-testing-enabled", "YES", "test"],
            mutationTestWorkers: 2,
            stopAtFirstFailure: .enabled
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true, true, true])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [true])
        XCTAssertEqual(notices(), [])
    }

    // A lone worker on the test command's destination tests in parallel, on clones, whose failed tests xcodebuild
    // reports in lines that can't stop a run: an explicit `true` says so once the worker is known.
    func test_aLoneWorkerOnTheDestination_thatTestsInParallel_runsToTheEnd_andAnExplicitTrueSaysWhy() async throws {
        testOneMutant(on: destination)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "-parallel-testing-enabled", "YES", "test"],
            stopAtFirstFailure: .enabled
        )
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(ioDelegate.configurations.map { $0.xcodeWorker?.destination }, [nil])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(notices().count, 1)
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.contains("`-destination \(destination)` tests in parallel"), reason)
    }

    // As the `.xctestrun` turns it on, and with the key unset, nothing is said.
    func test_aLoneWorkerOnTheDestination_whoseTestPlanTestsInParallel_runsToTheEnd() async throws {
        testOneMutant(on: destination)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"]
        )
        state.apply([.projectXCTestRun(testRun(with: ["BlueprintName": "AppTests", "ParallelizationEnabled": true]))])
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(notices(), [])
    }

    // `-skip-testing:<target>`, as the notice for a UI test target says, leaves it out, and stopping is back on.
    func test_aRunThatSkipsItsUITestTarget_stops() async throws {
        state.apply([.projectXCTestRun(testRun(with: ["BlueprintName": "AppUITests", "IsUITestBundle": true]))])
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "-skip-testing:AppUITests", "test"],
            mutationTestWorkers: 2,
            stopAtFirstFailure: .enabled
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true, true, true])
        XCTAssertEqual(notices(), [])
    }

    // MARK: - Helpers

    /// An `.xctestrun` whose one test configuration has `target` alone.
    private func testRun(with target: [String: AnyHashable]) -> muterCore.XCTestRun {
        let targets: [AnyHashable] = [target]
        let testConfiguration: [String: AnyHashable] = ["Name": "Test Scheme Action", "TestTargets": targets]
        let testConfigurations: [AnyHashable] = [testConfiguration]
        return XCTestRun(["TestConfigurations": testConfigurations])
    }
}
