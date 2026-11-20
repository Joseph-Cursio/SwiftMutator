@testable import muterCore
import XCTest

/// XCTest tests, and Linux's runners, run directly (#281).
extension PerformMutationTestingDirectRunTests {
    // Only `swift test` turns a filter into XCTest's test names, so the bundles aren't tried.
    func test_xctestTests_withATestFilter_leaveSwiftTest_withoutTryingTheBundles() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test", "--filter", "CoreTests"]
        )
        current.directTestRun = { [direct] _, _ in .success(direct.adding(["--filter", "CoreTests"])) }
        ioDelegate.baselineTestLog = xctestSummary + baselineLog
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [nil])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertEqual(sent(), [
            "the test command filters tests, and only `swift test` turns a filter into XCTest's test names",
        ])
    }

    func test_xctestTests_withAnOptionThatChangesTheirRun_leaveSwiftTest() async throws {
        current.directTestRun = { [direct] _, _ in .success(direct.adding(["--parallel"])) }
        ioDelegate.baselineTestLog = xctestSummary + baselineLog
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertEqual(sent(), ["the test command has --parallel, which changes how `swift test` runs XCTest tests"])
    }

    // `swift test --parallel` prints no XCTest summary, only a line for each test it starts, so its baseline names no
    // bundle, and a check run with no XCTest run would pass on the Swift Testing counts, dropping every XCTest test.
    func test_xctestTests_underParallelOnLinux_leaveSwiftTest_withoutTryingTheRunners() async throws {
        current.directTestRun = { _, _ in .success(Self.linux.adding(["--parallel"])) }
        ioDelegate.baselineTestLog = """
            [1/2] Testing XTests.CalcTests/testAdd
            [2/2] Testing XTests.CalcTests/testSubtract
            ✔ Test run with 3 tests in 1 suite passed after 0.001 seconds.

            """
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [nil])
        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [nil])
        XCTAssertEqual(sent(), ["the test command has --parallel, which changes how `swift test` runs XCTest tests"])
    }

    // A filtered XCTest run on Linux names no bundle's suite, only `Selected tests`, and still gives the filter's
    // reason.
    func test_xctestTests_withATestFilterOnLinux_leaveSwiftTest_forTheFilter() async throws {
        current.directTestRun = { _, _ in .success(Self.linux.adding(["--filter", "CalcTests"])) }
        ioDelegate.baselineTestLog = """
            Test Suite 'Selected tests' passed at 2026-11-20 23:15:53.292
            \t Executed 3 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds
            ✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.

            """
        let sent = recordNotices()

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurationsWithoutBuilding.map(\.directTestRun), [nil])
        XCTAssertEqual(sent(), [
            "the test command filters tests, and only `swift test` turns a filter into XCTest's test names",
        ])
    }

    private static let linux = DirectTestRun(
        platform: .linux,
        productsFolder: ".build/out/Products/Debug-linux-x86_64",
        bundles: ["CoreTests"],
        testFiles: [:],
        arguments: ["--skip-build"]
    )

    // A Swift Testing run alone takes the filter itself.
    func test_swiftTestingTestsAlone_withATestFilter_stillRunDirectly() async throws {
        let filtered = direct.adding(["--filter", "CoreTests"])
        current.directTestRun = { _, _ in .success(filtered) }
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."),
        ]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.directTestRun), [filtered])
    }

    // `xctest`'s bundle identifier fixes its tests' domain, which every worker's then shares, as under `swift test`.
    func test_workersThatRunXCTestTestsDirectly_areWarned() async throws {
        try useTwoWorkers()
        ioDelegate.baselineTestLog = xctestSummary + baselineLog
        ioDelegate.testRunsWithoutBuilding = [(.passed, xctestSummary + baselineLog)]
        let warnings = recordWarnings()

        _ = try await twoWorkers.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.first?.directTestRun?.xctestBundles, ["CoreTests"])
        XCTAssertEqual(warnings(), 1)
    }

    // A Linux runner's domain is its real name, in `~/.config`, which every worker shares, as under `swift test`.
    func test_workersThatRunDirectlyOnLinux_areWarned() async throws {
        try useTwoWorkers()
        current.directTestRun = { _, _ in .success(Self.linux) }
        ioDelegate.testRunsWithoutBuilding = [
            (.passed, "✔ Test run with 12 tests in 3 suites passed after 0.4 seconds."),
        ]
        let warnings = recordWarnings()

        _ = try await twoWorkers.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.first?.directTestRun?.platform, .linux)
        XCTAssertEqual(warnings(), 1)
    }
}
