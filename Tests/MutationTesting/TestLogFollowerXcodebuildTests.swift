@testable import muterCore
import XCTest

/// What stops an xcodebuild run at a crash, besides what stops a SwiftPM run: the Swift runtime's trap message and
/// xcodebuild's restart line, as `TestSuiteOutcome` reads them at the time limit. These follow real files.
final class TestLogFollowerXcodebuildTests: XCTestCase {
    private let pollInterval: TimeInterval = 0.005
    private let logFileUrl = URL(fileURLWithPath: XCTestCase.unusedTemporaryPath()).appendingPathComponent("test.log")
    private let trapLine = "Example/Parser.swift:10: Fatal error: Unexpectedly found nil while unwrapping an Optional"
    private let restartLine = "Restarting after unexpected exit, crash, or test timeout in ParserTests.testParse(); "
        + "summary will include totals from previous launches."

    func test_underXcodebuild_aTrapMessageIsACrash() async throws {
        try write("Test Case '-[ExampleTests.ParserTests testParse]' started.\n\(trapLine)\n")

        let stop = await firstStop(underXcodebuild: true)

        XCTAssertEqual(stop, .crashed(line: trapLine))
    }

    // A Swift Testing test that crashes under xcodebuild prints the runtime's message alone, with no restart line.
    func test_underXcodebuild_aSwiftTestingTestsTrap_isACrash() async throws {
        let trap = "Example/Parser.swift:12: Precondition failed: empty input"
        try write("◇ Test parse() started.\n\(trap)\n")

        let stop = await firstStop(underXcodebuild: true)

        XCTAssertEqual(stop, .crashed(line: trap))
    }

    // It follows a crash with no message too, such as a bad access.
    func test_underXcodebuild_theRestartLineIsACrash() async throws {
        try write("Test Case '-[ExampleTests.ParserTests testParse]' started.\n\n\(restartLine)\n")

        let stop = await firstStop(underXcodebuild: true)

        XCTAssertEqual(stop, .crashed(line: restartLine))
    }

    func test_underXcodebuild_aFailedTestLineBeforeATrap_isWhatItFinds() async throws {
        let failed = "Test Case '-[ExampleTests.ParserTests testParse]' failed (0.012 seconds)."
        try write("\(failed)\n\(trapLine)\n\(restartLine)\n")

        let stop = await firstStop(underXcodebuild: true)

        XCTAssertEqual(stop, .failedTest(line: failed))
    }

    func test_underXcodebuild_aSwiftTestingIssue_isAFailedTest() async throws {
        let issue = "✘ Test parse() recorded an issue at ParserTests.swift:8:5: Expectation failed: 1 == 2"
        try write("◇ Test parse() started.\n\(issue)\n")

        let stop = await firstStop(underXcodebuild: true)

        XCTAssertEqual(stop, .failedTest(line: issue))
    }

    // Parallel testing's line reads the same for a crash and a failed test, so it never stops a run; nor do text that
    // only mentions a trap, or the restart line inside another line.
    func test_underXcodebuild_parallelTestingsLinesAndTextInsideOtherLines_dontStopIt() async throws {
        try write("""
            Test case 'ParserTests.testParse()' failed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.01 seconds)
            Test case 'ParserTests.testOther()' passed on 'Clone 1 of iPhone 17 Pro - App (123)' (0.01 seconds)
            print: the Fatal errors chapter
            note: Restarting after unexpected exit, crash, or test timeout is what xcodebuild prints
            Test Case '-[ExampleTests.ParserTests testParse]' passed (0.001 seconds).

            """)

        let stop = await firstStop(underXcodebuild: true, cancellingAfter: 0.3)

        XCTAssertNil(stop)
    }

    // A run the simulator failed to launch shows neither a failed test nor a crash, so it runs to its end, and then
    // runs again (`TestRun.launchedOnceMore`).
    func test_underXcodebuild_aLaunchFailuresLog_doesntStopIt() async throws {
        for name in ["launch_preflightBusy.log", "launch_beforeEstablishingConnection.log"] {
            let log = try Data(contentsOf: URL(fileURLWithPath: "\(fixturesDirectory)/SimulatorTrouble/\(name)"))
            try write(String(lossyUTF8: log))

            let stop = await firstStop(underXcodebuild: true, cancellingAfter: 0.3)

            XCTAssertNil(stop, name)
        }
    }

    // A SwiftPM test process can print the runtime's message and go on; its signal line follows when it dies of it.
    func test_underSwiftPM_aTrapMessageOrARestartLine_doesntStopIt() async throws {
        try write("\(trapLine)\n\(restartLine)\n")

        let stop = await firstStop(underXcodebuild: false, cancellingAfter: 0.3)

        XCTAssertNil(stop)
    }

    // MARK: - Helpers

    /// Writes the whole log, as a test command would, in a folder removed once the test ends.
    private func write(_ text: String) throws {
        let directory = logFileUrl.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.createFile(atPath: logFileUrl.path, contents: Data(text.utf8)))
    }

    /// What a follower of the log finds, once it has read all of it; nil if it finds nothing within `timeout` seconds,
    /// when it is cancelled.
    private func firstStop(
        underXcodebuild: Bool,
        cancellingAfter timeout: TimeInterval = 5
    ) async -> TestRunEnding.Reason? {
        let follower = TestLogFollower(
            logFileUrl: logFileUrl, readsXcodebuildCrashes: underXcodebuild, pollInterval: pollInterval
        )
        let following = Task { await follower.firstStop() }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            following.cancel()
        }
        defer { deadline.cancel() }
        return await following.value
    }
}
