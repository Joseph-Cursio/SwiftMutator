@testable import muterCore
import TestingExtensions
import XCTest

/// An xcodebuild mutant's run on a Mac whose tests no app hosts stops as one on a simulator does, at a failed test or
/// at the Swift runtime's trap message; one whose tests an app hosts goes to its end.
extension MutationTestingDelegateTests {
    /// A Mac worker's configuration, one of several, as `SimulatorWorkerSetup.macWorkers` makes it, for tests that run
    /// in Xcode's `xctest` agent.
    private var macWorkerConfiguration: MuterConfiguration {
        MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=macOS", "test"],
            testSuiteTimeOut: 60
        )
        .withMacWorkerFact(given: .unhostedFixture)
        .forXcodeWorker(MuterConfiguration.XcodeWorker(
            testRunFile: "muter-worker1.xctestrun",
            derivedData: "/project_mutated_worker1.DerivedData.noindex",
            testDiagnosticsOff: true,
            parallelTestingOff: true
        ))
    }

    func test_anXcodebuildRunOnAMac_whoseTestsNoAppHosts_isStoppedAtItsFirstFailedTest() async throws {
        let failed = "Test Case '-[SumTests.SumTests testSum]' failed (0.012 seconds)."
        let testProcess = ScriptedProcessSpy([
            .write("Test Case '-[SumTests.SumTests testSum]' started.\n\(failed)\n", after: 0), .runUntilKilled,
        ])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: macWorkerConfiguration)

        XCTAssertEqual(result.outcome, .failed, result.testLog)
        XCTAssertEqual(result.ending, .stoppedAtFailedTest)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
        XCTAssertTrue(result.testLog.hasSuffix("[SwiftMutator] The line that stopped it: \(failed)\n"), result.testLog)
    }

    // The same lines show a crash on a Mac as on a simulator.
    func test_anXcodebuildRunOnAMac_whoseTestsNoAppHosts_isStoppedAtATrapOrARestartLine_asACrash() async throws {
        let crashLines = [
            "Sources/Sum/Sum.swift:10: Fatal error: Unexpectedly found nil while unwrapping an Optional value",
            "Restarting after unexpected exit, crash, or test timeout in SumTests.testSum(); summary will include "
                + "totals from previous launches.",
        ]
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        for crashLine in crashLines {
            let testProcess = ScriptedProcessSpy([
                .write("Test Case '-[SumTests.SumTests testSum]' started.\n\(crashLine)\n", after: 0), .runUntilKilled,
            ])

            let result = try await runMutantsTests(on: testProcess, using: macWorkerConfiguration)

            XCTAssertEqual(result.outcome, .runtimeError, result.testLog)
            XCTAssertEqual(result.ending, .stoppedAtCrash, crashLine)
            XCTAssertEqual(testProcess.terminateTreeCallCount, 1, crashLine)
        }
    }

    // An app host isn't xcodebuild's child, and nothing measured that stopping xcodebuild ends it, so a run whose tests
    // an app hosts goes to its end, whatever its log shows.
    func test_anXcodebuildRunOnAMac_whoseTestsAnAppHosts_isNotStopped() async throws {
        let testProcess = ScriptedProcessSpy([
            .write("Test Case '-[AppTests.SumTests testSum]' failed (0.012 seconds).\n", after: 0),
            .write("** TEST FAILED **\n", after: 0.3),
        ])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let configuration = MuterConfiguration(
            executable: "/tmp/xcodebuild",
            arguments: ["-scheme", "App", "-destination", "platform=macOS", "test"],
            testSuiteTimeOut: 60,
            stopAtFirstFailure: .enabled
        ).withMacWorkerFact(given: .withTestTargets([
            "AppTests": ["TestHostPath": muterCore.XCTestRun.macAppPath, "IsAppHostedTestBundle": true],
        ]))

        let result = try await runMutantsTests(on: testProcess, using: configuration)

        XCTAssertEqual(result.outcome, .failed, result.testLog)
        XCTAssertEqual(result.ending, .exited)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
        XCTAssertTrue(result.testLog.contains("** TEST FAILED **"), result.testLog)
    }

    // As on a simulator, so that a stopped run shows its failure in its log.
    func test_anXcodebuildRunOnAMac_whoseTestsNoAppHosts_writesUnbuffered() throws {
        current.process = {
            let process = MuterProcessFactory.makeProcess()
            process.environment?["NSUnbufferedIO"] = nil
            return process
        }
        let mutant = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        let testProcess = try sut.testProcess(
            with: macWorkerConfiguration,
            schemata: mutant,
            and: FileHandle(fileDescriptor: 0)
        )

        XCTAssertEqual(testProcess.environment?["NSUnbufferedIO"], "YES")
    }
}
