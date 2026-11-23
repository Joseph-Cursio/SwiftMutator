@testable import muterCore
import TestingExtensions
import XCTest

/// Which xcodebuild runs' mutants on a Mac stop at their first failed test: those whose tests run in Xcode's `xctest`
/// agent, xcodebuild's own child, unless a lone worker tests in parallel; not a Mac app's hosted tests or Mac Catalyst.
extension PerformMutationTestingXcodeWorkersTests {
    // On by default, as on a simulator: every mutant's run on every worker stops, and the baseline writes unbuffered,
    // as the runs that stop do.
    func test_macWorkers_whoseTestsNoAppHosts_stopAtTheirFirstFailedTest_andTheHeaderSaysSo() async throws {
        testOnAMac(arguments: [], workers: 2, stopAtFirstFailure: .unset)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [true, true, true, true])
        XCTAssertTrue(
            ioDelegate.configurations.allSatisfy { $0.xcodeWorker?.parallelTestingOff == true },
            "several workers, each testing one test at a time"
        )
        XCTAssertEqual(ioDelegate.baselineConfigurations.map(\.stopsAtFirstFailure), [true])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [true])
        XCTAssertEqual(notices(), [])
    }

    // An app host isn't xcodebuild's child, and nothing measured that stopping xcodebuild ends it: an explicit `true`
    // says so before the baseline, and the runs, on one worker, go to their end.
    func test_aMacAppsHostedTests_runToTheirEnd_andAnExplicitTrueSaysWhy() async throws {
        testOnAMac(arguments: [], workers: 2, stopAtFirstFailure: .enabled)
        state.projectXCTestRun = .withTestTargets([
            "AppTests": ["TestHostPath": muterCore.XCTestRun.macAppPath, "IsAppHostedTestBundle": true],
        ])
        var atTheBaseline: [String] = []
        let notices = sentStopNotices()
        ioDelegate.whileRunningBaseline = { _ in atTheBaseline = notices() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(ioDelegate.baselineConfigurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(notices().count, 1)
        XCTAssertEqual(atTheBaseline, notices())
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.contains("on `-destination platform=macOS` an app hosts some of them"), reason)
        XCTAssertTrue(reason.contains("an app host isn't a child of xcodebuild"), reason)
        XCTAssertTrue(reason.contains("nothing measured that stopping a run ends its tests"), reason)
    }

    func test_aMacAppsHostedTests_withTheKeyUnset_nothingIsSaid() async throws {
        testOnAMac(arguments: [], workers: nil, stopAtFirstFailure: .unset)
        state.projectXCTestRun = .withTestTargets([
            "AppTests": ["TestHostPath": muterCore.XCTestRun.macAppPath, "IsAppHostedTestBundle": true],
        ])
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(notices(), [])
    }

    func test_macCatalyst_runsToItsEnd_andAnExplicitTrueSaysWhy() async throws {
        testOnAMac(
            arguments: [], workers: 2, stopAtFirstFailure: .enabled, destination: "platform=macOS,variant=Mac Catalyst"
        )
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false, false, false, false])
        XCTAssertEqual(notices().count, 1)
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.contains("names Mac Catalyst"), reason)
    }

    // A lone worker on the Mac that tests in parallel runs its tests in several processes, whose failed tests show
    // only in lines that can't stop a run: an explicit `true` says so once the worker is known.
    func test_aLoneMacWorker_thatTestsInParallel_runsToTheEnd_andAnExplicitTrueSaysWhy() async throws {
        testOneMutant(on: "platform=macOS")
        testOnAMac(arguments: ["-parallel-testing-enabled", "YES"], workers: nil, stopAtFirstFailure: .enabled)
        let notices = sentStopNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(ioDelegate.configurations.map { $0.xcodeWorker?.parallelTestingOff }, [false])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.stopsAtFirstFailure), [false])
        XCTAssertEqual(notices().count, 1)
        let reason = try XCTUnwrap(notices().first)
        XCTAssertTrue(reason.contains("`-destination platform=macOS` tests in parallel, in several test processes"))
    }

    // MARK: - Helpers

    /// Tests on `destination`, a Mac, whose one test target runs in Xcode's `xctest` agent, with `arguments` before
    /// `test`, `workers` asked for, and `stopAtFirstFailure`; each mutant's run fails.
    private func testOnAMac(
        arguments: [String],
        workers: Int?,
        stopAtFirstFailure: ConfigurationSwitch,
        destination: String = "platform=macOS"
    ) {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "App", "-destination", destination] + arguments + ["test"],
            mutationTestWorkers: workers,
            stopAtFirstFailure: stopAtFirstFailure
        )
        state.projectXCTestRun = .unhostedFixture
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: state.mutationMapping.count)
    }
}
