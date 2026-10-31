@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// Running a SwiftPM project's test bundles without `swift test`, once a run of them with no mutant on matches the
/// baseline.
final class PerformMutationTestingDirectRunTests: MuterTestCase {
    private let state = MutationTestState()
    private let sut = PerformMutationTesting(makeWorkerDirectories: { _, _ in [] }, removeWorkerDirectories: { _ in })
    private let direct = DirectTestRun(
        helper: "/toolchain/usr/libexec/swift/pm/swiftpm-testing-helper",
        productsFolder: ".build/out/Products/Debug",
        bundles: ["CoreTests"],
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
        ioDelegate.testRunsWithoutBuilding = [(.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds.")]
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(probed.value, [state.mutatedProjectDirectoryURL])
        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [direct])
        XCTAssertEqual(ioDelegate.testLogs.filter { $0.hasSuffix("test run") }, ["/logs/running/direct test run"])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [direct])
        XCTAssertEqual(sent(), [])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.testBundlesRunDirectly, true)
        XCTAssertNotNil(header.testRunSeconds)
        // The configuration as loaded, which the header records, has none.
        XCTAssertNil(header.configuration.directTestRun)
    }

    func test_aRunThatRunsOtherTests_leavesSwiftTest_andIsTimedAgain() async throws {
        ioDelegate.testRunsWithoutBuilding = [(.passed, "✔ Test run with 9 tests in 3 suites passed after 0.4 seconds.")]
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [direct, nil])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertEqual(sent().count, 1)
        XCTAssertTrue(sent().first?.contains("ran 9 Swift Testing tests, where `swift test` ran 12") ?? false)
        XCTAssertNil(try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first).testBundlesRunDirectly)
    }

    func test_aRunThatFails_leavesSwiftTest() async throws {
        ioDelegate.testRunsWithoutBuilding = [(.runtimeError, "")]
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertTrue(sent().first?.contains("didn't pass") ?? false)
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
        ioDelegate.testRunsWithoutBuilding = [(.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds.")]

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

    private func makeSchemataMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: 1, line: 1, column: 0),
                        snapshot: .null
                    ),
                ]
            )
        )
    }
}
