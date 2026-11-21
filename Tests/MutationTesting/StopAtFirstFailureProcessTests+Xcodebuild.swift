@testable import muterCore
import XCTest

/// Real test commands that stand for xcodebuild on a simulator: a script that ignores the arguments of a mutant's run,
/// `test-without-building -destination … -xctestrun …`, and prints what xcodebuild prints.
extension StopAtFirstFailureProcessTests {
    func test_aRealXcodebuildRun_isStoppedAtAnXCTestFailure_andLeavesNothingRunning() async throws {
        try await assertStopped(
            at: "Test Case '-[AppTests.SumTests testSum]' failed (0.012 seconds).",
            as: .failed,
            endedBy: .stoppedAtFailedTest
        )
    }

    func test_aRealXcodebuildRun_isStoppedAtASwiftTestingIssue_andLeavesNothingRunning() async throws {
        try await assertStopped(
            at: "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4",
            as: .failed,
            endedBy: .stoppedAtFailedTest
        )
    }

    func test_aRealXcodebuildRun_isStoppedAtTheRestartLine_asACrash_andLeavesNothingRunning() async throws {
        try await assertStopped(
            at: "Restarting after unexpected exit, crash, or test timeout in SumTests.testSum(); summary will include "
                + "totals from previous launches.",
            as: .runtimeError,
            endedBy: .stoppedAtCrash
        )
    }

    // A Swift Testing test that crashes under xcodebuild prints the runtime's line alone.
    func test_aRealXcodebuildRun_isStoppedAtATrapMessage_asACrash_andLeavesNothingRunning() async throws {
        try await assertStopped(
            at: "App/Sum.swift:7: Fatal error: Index out of range",
            as: .runtimeError,
            endedBy: .stoppedAtCrash
        )
    }

    // Nothing measured that stopping xcodebuild ends a Mac's test process, so the run goes to its end.
    func test_aRealXcodebuildRunOnAMac_goesToItsEnd() async throws {
        let configuration = try xcodebuildCommand(testingOn: "platform=macOS", running: """
            echo "Test Case '-[AppTests.SumTests testSum]' failed (0.012 seconds)."
            /bin/sleep 0.3
            echo "** TEST FAILED **"
            exit 65
            """)

        let result = try await runMutantsTests(using: configuration)

        XCTAssertEqual(result.ending, .exited, result.testLog)
        XCTAssertEqual(result.exitStatus, 65)
        XCTAssertEqual(result.outcome, .failed, result.testLog)
        XCTAssertTrue(result.testLog.contains("** TEST FAILED **"), result.testLog)
    }

    // MARK: - Helpers

    /// Runs a script on a simulator that starts a child, as xcodebuild does its test runner, prints `line`, and waits
    /// for the child, and checks that the run stops at `line` with `outcome`, well before the child's own end, and that
    /// the child is gone. The sleep's odd length makes it easy to find if it's left behind.
    private func assertStopped(
        at line: String,
        as outcome: TestSuiteOutcome,
        endedBy ending: TestRun.Ending,
        file: StaticString = #filePath,
        sourceLine: UInt = #line
    ) async throws {
        let configuration = try xcodebuildCommand(
            testingOn: "platform=iOS Simulator,name=iPhone 17 Pro",
            running: """
                /bin/sleep 30.2626 & echo $! > child.pid
                echo "Test Case '-[AppTests.SumTests testSum]' started."
                echo "\(line)"
                wait
                """
        )

        let started = Date()
        let result = try await runMutantsTests(using: configuration)

        XCTAssertEqual(result.outcome, outcome, result.testLog, file: file, line: sourceLine)
        XCTAssertEqual(result.ending, ending, result.testLog, file: file, line: sourceLine)
        XCTAssertTrue(
            result.testLog.contains("[SwiftMutator] The line that stopped it: \(line)"),
            result.testLog,
            file: file,
            line: sourceLine
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, file: file, line: sourceLine)
        let child = try XCTUnwrap(pid(writtenTo: "child.pid"), file: file, line: sourceLine)
        XCTAssertTrue(
            Self.waitUntil(within: 2) { isGone(child) },
            "the test command's child is still running",
            file: file,
            line: sourceLine
        )
    }

    /// A script in this test's folder that runs `script` as xcodebuild's test command, testing on `destination`, with
    /// `buildSystem: xcodebuild`, as a wrapper script has it. It ignores its arguments.
    private func xcodebuildCommand(testingOn destination: String, running script: String) throws -> MuterConfiguration {
        let path = directory.appendingPathComponent("xcodebuild.sh").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(script)\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return MuterConfiguration(
            executable: path,
            arguments: ["-scheme", "App", "-destination", destination, "test"],
            testSuiteTimeOut: 60,
            buildSystem: .xcodebuild
        )
    }
}
