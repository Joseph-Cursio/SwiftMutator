@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// Running a SwiftPM project's test bundles without `swift test`, once a run of them with no mutant on matches the
/// baseline.
final class PerformMutationTestingDirectRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = PerformMutationTesting(makeWorkerDirectories: { _, _ in [] }, removeWorkerDirectories: { _ in })
    private let twoWorkers = PerformMutationTesting(
        makeWorkerDirectories: { _, count in
            Array(repeating: URL(fileURLWithPath: "/project_mutated_worker1"), count: count)
        },
        removeWorkerDirectories: { _ in }
    )
    private let direct = DirectTestRun(
        helper: "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper",
        productsFolder: ".build/out/Products/Debug",
        bundles: ["CoreTests"],
        testFiles: [:],
        platformDeveloperFolder: "/Platforms/MacOSX.platform/Developer",
        arguments: ["--skip-build"]
    )
    private let baselineLog = """
        Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds
        ✔ Test run with 12 tests in 3 suites passed after 0.5 seconds.
        """
    private let probed = Locked<[URL]>([])

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.mutationMapping = try [makeSchemataMapping()]
        ioDelegate.baselineTestLog = baselineLog
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
    }

    // After `MuterTestCase.setUp()`, which replaces `current`.
    override func setUp() {
        super.setUp()

        current.directTestRun = { [direct, probed] _, project in
            probed.change { $0.append(project) }
            return .success(direct)
        }
    }

    func test_aRunThatMatchesTheBaseline_isTheTimedRun_andMutantsRunTheBundlesDirectly() async throws {
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."),
        ]
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(probed.value, [state.mutatedProjectDirectoryURL])
        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [direct])
        XCTAssertEqual(ioDelegate.testLogs.filter { $0.hasSuffix("test run") }, ["/logs/running/direct test run"])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [direct])
        XCTAssertEqual(sent(), [])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertTrue(header.testBundlesRunDirectly)
        XCTAssertNotNil(header.testRunSeconds)
        // The configuration as loaded, which the header records, has none.
        XCTAssertNil(header.configuration.directTestRun)
        // Its output is moved to the timed test run's log, which it is.
        XCTAssertTrue(
            ioDelegate.keptOutputs.contains { $0 == ("/logs/running/direct test run", "/logs/timed test run.log") },
            "\(ioDelegate.keptOutputs)"
        )
    }

    func test_aRunThatRunsOtherTests_leavesSwiftTest_andIsTimedAgain() async throws {
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 9 tests in 3 suites passed after 0.4 seconds."),
        ]
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [direct, nil])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertEqual(sent().count, 1)
        XCTAssertTrue(sent().first?.contains("ran 9 Swift Testing tests, where `swift test` ran 12") ?? false)
        XCTAssertFalse(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).testBundlesRunDirectly)
    }

    func test_aRunThatFails_leavesSwiftTest() async throws {
        ioDelegate.testRunsWithoutBuilding = [(.runtimeError, "")]
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertTrue(sent().first?.contains("didn't pass") ?? false)
        // Its output is moved to the log the notice names, and the timed run that follows keeps its own.
        XCTAssertTrue(
            ioDelegate.keptOutputs.contains { $0 == ("/logs/running/direct test run", "/logs/direct test run.log") },
            "\(ioDelegate.keptOutputs)"
        )
        XCTAssertTrue(
            ioDelegate.keptOutputs.contains { $0 == ("/logs/running/timed test run", "/logs/timed test run.log") },
            "\(ioDelegate.keptOutputs)"
        )
    }

    // `swift test` runs XCTest tests with `xctest`, which running the bundles directly doesn't.
    func test_aBaselineThatRanXCTestTests_leavesSwiftTest_withoutTryingTheBundles() async throws {
        ioDelegate.baselineTestLog = "Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
            + baselineLog
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [nil])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertTrue(sent().first?.contains("XCTest") ?? false)
    }

    func test_aProbeThatFailsWithAReason_saysIt() async throws {
        current.directTestRun = { _, _ in .failure(.init(reason: "no helper")) }
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent(), ["no helper"])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
    }

    // On Linux, or with a wrapper as `executable`, the bundles aren't for running directly, which isn't news.
    func test_aProbeThatFailsWithoutAReason_saysNothing() async throws {
        current.directTestRun = { _, _ in .failure(.init(reason: nil)) }
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(sent(), [])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
    }

    // With a configured time limit nothing needs timing, but the bundles are still checked before they're used.
    func test_aConfiguredTimeLimit_stillChecksTheBundles() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42
        )
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."),
        ]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.count, 1)
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [direct])
        XCTAssertEqual(ioDelegate.configurations.map(\.testSuiteTimeout), [42])
    }

    func test_anotherBuildSystem_isNeverProbed() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])

        _ = try await sut.run(with: state)

        XCTAssertEqual(probed.value, [])
    }

    // Workers that run through `swift test` share `UserDefaults.standard`, which only a direct run's don't (#92).
    func test_workersOnSwiftTest_areWarnedTheyShareUserDefaults() async throws {
        try useTwoWorkers()
        ioDelegate.baselineTestLog = "Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
            + baselineLog
        let warnings = recordWarnings()

        _ = try await twoWorkers.run(with: state)

        XCTAssertEqual(warnings(), 1)
    }

    func test_workersThatFailTheDirectRun_areWarned() async throws {
        try useTwoWorkers()
        ioDelegate.testRunsWithoutBuilding = [(.runtimeError, "")]
        let warnings = recordWarnings()

        _ = try await twoWorkers.run(with: state)

        XCTAssertEqual(warnings(), 1)
    }

    // On Linux, which says nothing of direct runs, workers share them just the same.
    func test_workersWithAProbeThatGivesNoReason_areWarned() async throws {
        try useTwoWorkers()
        current.directTestRun = { _, _ in .failure(.init(reason: nil)) }
        let warnings = recordWarnings()

        _ = try await twoWorkers.run(with: state)

        XCTAssertEqual(warnings(), 1)
    }

    func test_workersThatRunDirectly_arentWarned() async throws {
        try useTwoWorkers()
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."),
        ]
        let warnings = recordWarnings()

        _ = try await twoWorkers.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [direct, direct])
        XCTAssertEqual(warnings(), 0)
    }

    func test_oneWorkerOnSwiftTest_isntWarned() async throws {
        ioDelegate.baselineTestLog = "Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
            + baselineLog
        let warnings = recordWarnings()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertEqual(warnings(), 0)
    }

    // One asked for two workers but with one mutant to test gets one.
    func test_moreWorkersThanMutants_isntWarned() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        ioDelegate.baselineTestLog = "Executed 4 tests, with 0 failures (0 unexpected) in 0.1 (0.1) seconds\n"
            + baselineLog
        let warnings = recordWarnings()

        _ = try await sut.run(with: state)

        XCTAssertEqual(warnings(), 0)
    }

    /// A run of two mutants on two workers. The baseline, the clone's build, then the mutants.
    private func useTwoWorkers() throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try [makeSchemataMapping(), makeSchemataMapping(line: 2)]
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .failed]
    }

    /// How many times `workersShareUserDefaults` has been sent from now on.
    private func recordWarnings() -> () -> Int {
        let count = Locked(0)
        let token = runEvents.observe(.workersShareUserDefaults) { _ in count.change { $0 += 1 } }
        addTeardownBlock { token.cancel() }
        return { count.value }
    }

    // With a buildTimeout, the direct run follows the baseline as the timed test run does, and has its limit. Stopped
    // there, it fails the check, so mutants run through `swift test`, and the timed test run, with the same limit,
    // times that.
    func test_aDirectRunPastItsLimit_leavesSwiftTest_andTheTimedRunHasTheSameLimit() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 600
        )
        ioDelegate.testRunsWithoutBuildingWritingTo["direct test run"] = (.failed, "Test Suite 'All tests' started")
        ioDelegate.endingsWithoutBuildingWritingTo["direct test run"] = .timedOut
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.timeLimitsWithoutBuilding, [60, 60])
        XCTAssertEqual(sent(), [
            "the run of the test bundles with no mutant on didn't end within 60 s, so SwiftMutator stopped it "
                + "(its log is direct test run.log)",
        ])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
    }

    // Its limit comes from the baseline's own time, as the timed test run's does.
    func test_aDirectRunsLimit_isFiveTimesTheBaselinesTime() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], buildTimeout: 3_600
        )
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."),
        ]
        let nanoseconds = Locked<UInt64>(1_000_000_000)
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds.value) }
        ioDelegate.whileRunningBaseline = { _ in nanoseconds.change { $0 += 200_000_000_000 } }

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.timeLimitsWithoutBuilding, [1_000])
    }

    /// The reason of each `testBundlesNotRunDirectly` sent from now on.
    private func recordNotices() -> () -> [String] {
        let reasons = Locked<[String]>([])
        let token = runEvents.observe(.testBundlesNotRunDirectly) { event in
            if case let .testBundlesNotRunDirectly(reason) = event {
                reasons.change { $0.append(reason) }
            }
        }
        addTeardownBlock { token.cancel() }
        return { reasons.value }
    }

    private func makeSchemataMapping(line: Int = 1) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line, line: line, column: 0),
                        snapshot: .null
                    ),
                ]
            )
        )
    }
}
