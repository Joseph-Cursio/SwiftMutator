@testable import muterCore
import TestingExtensions
import XCTest

/// Which xcodebuild runs' mutants stop at their first failed test: those on a simulator.
extension PerformMutationTestingXcodeWorkersTests {
    // Each worker tests on a simulator of its own, so with the key unset every mutant's run stops, as SwiftPM's do.
    func test_mutantsOnTheWorkersSimulators_stopAtTheirFirstFailedTest() async throws {
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true, true, true])
        XCTAssertTrue(ioDelegate.configurations.allSatisfy { $0.xcodeWorker?.destination != nil })
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [true])
        XCTAssertEqual(notices(), [])
    }

    // Nothing measured that stopping xcodebuild ends a Mac's test process: an explicit `true` says why it's off.
    func test_onAMacDestination_mutantsRunToTheirEnd_andAnExplicitTrueSaysWhy() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"],
            mutationTestWorkers: 2,
            stopAtFirstFailure: .enabled
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [false])
        let reason = try XCTUnwrap(state.muterConfiguration.stopAtFirstFailureUnsupportedReason)
        XCTAssertTrue(reason.contains("names a Mac"), reason)
        XCTAssertEqual(notices(), [reason])
    }

    func test_onAMacDestination_withTheKeyUnset_nothingIsSaid() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-destination", "platform=macOS", "test"]
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(notices(), [])
    }

    // As a passing baseline's: a test that prints text shaped like a failure would stop every mutant's run.
    func test_aCheckRunThatPrintsAFailureLikeLine_turnsStoppingOff_andSaysSo() async throws {
        let lookalike = "Test Case '-[AppTests.ReporterTests testSample]' failed (0.001 seconds)."
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 1"] = (
            .passed, "Test Suite 'All tests' started.\n\(lookalike)\n** TEST SUCCEEDED **"
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false, false, false])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(notices().count, 1)
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.hasPrefix("a worker's run with no mutant on passed"), reason)
        XCTAssertTrue(reason.hasSuffix("\n  \(lookalike)"), reason)
    }

    // With stopping already off, the check run's line changes nothing worth a notice.
    func test_aCheckRunThatPrintsAFailureLikeLine_withStoppingOff_isNotSaid() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            stopAtFirstFailure: .disabled
        )
        ioDelegate.testRunsWithoutBuildingWritingTo["no-mutant run worker 0"] = (
            .passed, "Example/Parser.swift:10: Precondition failed: caught\n** TEST SUCCEEDED **"
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.failedTestLinesAreReliable), [false, false, false, false])
        XCTAssertEqual(notices(), [])
    }

    // A bare `id=` can name a device: one mutant, which tests on the destination, stops only once simctl lists it.
    func test_aDestinationNamedByItsIdAlone_thatSimctlLists_stops() async throws {
        let bare = "id=693E96A4-0E5B-4F3A-9E4C-2A39F5C8D1B7"
        testOneMutant(on: bare)
        workerSimulators.listing([bare])
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated", "list \(bare)"])
        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true])
        XCTAssertEqual(notices(), [])
    }

    func test_aDestinationNamedByItsIdAlone_thatSimctlDoesntList_runsToTheEnd_andSaysWhy() async throws {
        let bare = "id=00008110-000A1B2C3D4E5F6A"
        testOneMutant(on: bare)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(notices().count, 1)
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.contains("simctl lists none that `-destination \(bare)` names"), reason)
    }

    // The app a UI test drives can outlive a stopped run, which #81's measurement didn't cover.
    func test_aRunThatTestsAUITestTarget_runsToItsEnd_andAnExplicitTrueSaysWhy() async throws {
        let target: [String: AnyHashable] = ["BlueprintName": "AppUITests", "IsUITestBundle": true]
        let targets: [AnyHashable] = [target]
        let testConfiguration: [String: AnyHashable] = ["Name": "Test Scheme Action", "TestTargets": targets]
        let testConfigurations: [AnyHashable] = [testConfiguration]
        state.apply([.projectXCTestRun(XCTestRun(["TestConfigurations": testConfigurations]))])
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            mutationTestWorkers: 2,
            stopAtFirstFailure: .enabled
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(notices().count, 1)
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.contains("UI tests (`AppUITests`)"), reason)
    }

    // MARK: - Helpers

    /// One mutant to test, which needs no simulator of its own, on `destination`, with `stopAtFirstFailure: true`.
    func testOneMutant(on destination: String) {
        state.mutationMapping = Array(state.mutationMapping.prefix(1))
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            stopAtFirstFailure: .enabled
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
    }

    /// The reasons of the notices that stopping at the first failed test is off, sent from now on.
    func sentStopNotices() -> () -> [String] {
        var reasons: [String] = []
        whenSent(.stopAtFirstFailureTurnedOff) { event in
            if case let .stopAtFirstFailureTurnedOff(reason) = event { reasons.append(reason) }
        }
        return { reasons }
    }
}
