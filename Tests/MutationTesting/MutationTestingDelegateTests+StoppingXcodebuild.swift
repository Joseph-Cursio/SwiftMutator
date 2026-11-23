@testable import muterCore
import TestingExtensions
import XCTest

/// An xcodebuild mutant's run on a simulator stops as `swift test`'s does, and at a crash also on the Swift runtime's
/// trap message or xcodebuild's restart line.
extension MutationTestingDelegateTests {
    var xcodebuildStoppingConfiguration: MuterConfiguration {
        MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=iOS Simulator,name=iPhone 17 Pro", "test"],
            testSuiteTimeOut: 60
        )
    }

    func test_anXcodebuildRunOnASimulator_isStoppedAtItsFirstFailedTest() async throws {
        let failed = "Test Case '-[AppTests.SumTests testSum]' failed (0.012 seconds)."
        let testProcess = ScriptedProcessSpy([
            .write("Test Case '-[AppTests.SumTests testSum]' started.\n\(failed)\n", after: 0), .runUntilKilled,
        ])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: xcodebuildStoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed, result.testLog)
        XCTAssertEqual(result.ending, .stoppedAtFailedTest)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
        XCTAssertTrue(result.testLog.hasSuffix("[SwiftMutator] The line that stopped it: \(failed)\n"), result.testLog)
    }

    // As `TestSuiteOutcome` scores these lines at the time limit: a crash, so a runtime error.
    func test_anXcodebuildRunOnASimulator_isStoppedAtATrapOrARestartLine_asACrash() async throws {
        let crashLines = [
            "Example/Parser.swift:10: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
            "Restarting after unexpected exit, crash, or test timeout in SumTests.testSum(); summary will include "
                + "totals from previous launches.",
        ]
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        for crashLine in crashLines {
            let testProcess = ScriptedProcessSpy([
                .write("Test Case '-[AppTests.SumTests testSum]' started.\n\(crashLine)\n", after: 0), .runUntilKilled,
            ])

            let result = try await runMutantsTests(on: testProcess, using: xcodebuildStoppingConfiguration)

            XCTAssertEqual(result.outcome, .runtimeError, result.testLog)
            XCTAssertEqual(result.ending, .stoppedAtCrash, crashLine)
            XCTAssertEqual(testProcess.terminateTreeCallCount, 1, crashLine)
            // xcodebuild would have gone on to the tests after it, in a new runner.
            XCTAssertTrue(
                result.testLog.contains("Stopped this test run at a crash (stopAtFirstFailure); the tests after it "
                    + "did not run.\n[SwiftMutator] The line that stopped it: \(crashLine)\n"),
                result.testLog
            )
        }
    }

    // SwiftPM's test process can print the runtime's message and go on: its signal line, not this, shows the crash.
    func test_aSwiftPMRun_isNotStoppedAtATrapMessage() async throws {
        let testProcess = ScriptedProcessSpy([
            .write("Example/Parser.swift:10: Fatal error: caught by the test\n\(passedTestLine)\n", after: 0),
            .write("✔ Test run with 1 test in 1 suite passed after 0.301 seconds.\n", after: 0.3),
        ])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .passed, result.testLog)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
    }

    // So that a run stopped at its first failed test shows that failure in its log, whatever buffers xcodebuild's own
    // output. A worker's check run too, though it is never stopped, as the baseline is for `swift test`.
    func test_anXcodebuildRunOnASimulator_writesUnbuffered() throws {
        current.process = {
            let process = MuterProcessFactory.makeProcess()
            process.environment?["NSUnbufferedIO"] = nil
            return process
        }
        let mutant = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        for schemata in [mutant, .null] {
            let testProcess = try sut.testProcess(
                with: xcodebuildStoppingConfiguration,
                schemata: schemata,
                and: FileHandle(fileDescriptor: 0)
            )

            XCTAssertEqual(testProcess.environment?["NSUnbufferedIO"], "YES", schemata.id)
        }
    }
}
