@testable import muterCore
import TestingExtensions
import XCTest

extension MutationTestingDelegateTests {
    // Any failed test kills a mutant, so the tests after it can't change its outcome.
    func test_whenAMutantsRunShowsAFailedTest_thenItIsStoppedThereAndCountsAsKilled() async throws {
        let testProcess = ScriptedProcessSpy(
            [.write("\(passedTestLine)\n\(failedTestLine)\n", after: 0), .runUntilKilled]
        )
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let started = Date()
        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
        // Only once it has ended, so that a shell has started the last process it will.
        XCTAssertEqual(testProcess.killProcessGroupCallCount, 1)
        XCTAssertTrue(testProcess.hadEndedAtTheGroupKill)
        // Well under the process's own deadline, so the failed test, not that deadline, ended the run.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    // A stopped run's log ends where it was killed, often partway through a line, with no summary. The note
    // says why, and which line stopped it, without its colour codes.
    func test_whenARunIsStoppedAtItsFirstFailure_thenItsLogEndsWithANoteNamingTheLine() async throws {
        let colouredFailedTestLine = "\u{1B}[91m✘\u{1B}[0m"
            + " Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4"
        let output = "\(passedTestLine)\n\(colouredFailedTestLine)\n↳ 5 == 4 → false\n✔ Test other() pass"
        let testProcess = ScriptedProcessSpy([.write(output, after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.testLog, output + """


            [SwiftMutator] Stopped this test run at its first failed test (stopAtFirstFailure); the tests after it \
            did not run.
            [SwiftMutator] The line that stopped it: \(failedTestLine)

            """)
    }

    // A blank line sets the note apart, whether the run was killed after a whole line or partway through one.
    func test_theNoteForAStoppedRun_followsABlankLine() {
        for log in ["\(failedTestLine)\n", "\(failedTestLine)\n✔ Test other() pass"] {
            let notedLog = log + MutationTestingDelegate.noteForRunStopped(at: failedTestLine, after: log)

            XCTAssertTrue(notedLog.contains("\n\n[SwiftMutator] Stopped this test run"), notedLog)
        }
    }

    // Whether the baseline passes decides whether mutation testing can start, so it always runs to its end.
    func test_theBaselineIsNeverStoppedAtAFailedTest() async throws {
        for workingDirectory in [nil, outputFolderURL] {
            let testProcess = ScriptedProcessSpy([
                .write("\(failedTestLine)\n", after: 0),
                .write("\(failedRunSummary)\n", after: 0.3),
            ])
            current.process = { testProcess }

            let result: TestRun
            if let workingDirectory {
                result = await sut.benchmarkTests(
                    using: stoppingConfiguration,
                    savingResultsIntoFileNamed: "logFileName",
                    workingDirectory: workingDirectory
                )
            } else {
                result = await sut.benchmarkTests(
                    using: stoppingConfiguration,
                    savingResultsIntoFileNamed: "logFileName"
                )
            }

            let overload = workingDirectory == nil ? "in the project" : "in a worker's clone"
            XCTAssertEqual(testProcess.terminateTreeCallCount, 0, overload)
            XCTAssertTrue(result.testLog.contains(failedRunSummary), "\(overload): \(result.testLog)")
        }
    }

    func test_whenStopAtFirstFailureIsOff_thenAFailingRunGoesToTheEnd() async throws {
        let configurations = [
            MuterConfiguration(
                executable: "/tmp/swift",
                arguments: ["test"],
                testSuiteTimeOut: 60,
                stopAtFirstFailure: false
            ),
            // On by default, but a wrapper script counts as `swift test` only with `buildSystem: swift`.
            MuterConfiguration(executable: "/tmp/run-tests.sh", arguments: ["test"], testSuiteTimeOut: 60),
            // A kill tested again alone, in the environment of a run that stops.
            MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 60)
                .goingToEachRunsEnd(),
            // Switched on, but xcodebuild runs can't be stopped.
            MuterConfiguration(
                executable: "/tmp/xcodebuild",
                arguments: ["test"],
                testSuiteTimeOut: 60,
                stopAtFirstFailure: true
            ),
        ]
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        for configuration in configurations {
            let testProcess = ScriptedProcessSpy([
                .write("\(failedTestLine)\n", after: 0),
                .write("\(failedRunSummary)\n", after: 0.3),
            ])

            let result = try await runMutantsTests(on: testProcess, using: configuration)

            let description = "\(configuration.testCommandExecutable), "
                + "\(String(describing: configuration.stopAtFirstFailure))"
            XCTAssertEqual(testProcess.terminateTreeCallCount, 0, description)
            XCTAssertEqual(result.outcome, .failed, description)
            XCTAssertTrue(result.testLog.contains(failedRunSummary), "\(description): \(result.testLog)")
        }
    }

    // Only a failing issue kills a mutant: a known issue or a warning leaves its test passing.
    func test_knownIssuesAndWarnings_doNotStopTheRun() async throws {
        let testProcess = ScriptedProcessSpy([
            .write("""
                ━ Test knownIssue() recorded a known issue at ATests.swift:34:13: Expectation failed: 1 == 2
                ⚠︎ Test recordsWarning() recorded a warning at CTests.swift:35:21: Issue recorded
                \(passedTestLine)

                """, after: 0),
            .write("✔ Test run with 3 tests in 1 suite passed after 0.301 seconds with 1 known issue.\n", after: 0.3),
        ])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let started = Date()
        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .passed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
        // Well under the time limit and runMutantsTests' cancel: the run ends with its process, although the
        // follower was still watching the log.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the run outlived its process")
    }

    // The time limit can fire while a run is being stopped at its failed test. Its handler may not kill the
    // process again, and the run counts as stopped there, which kills the mutant, not as timed out.
    func test_whenTheTimeLimitFiresAfterTheRunWasStopped_thenItCountsAsKilledAndIsKilledOnce() async throws {
        testingTimeOutExecutor.firesAfterBody = true
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n", after: 0), .runUntilKilled])

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 1)
    }

    // A run whose last test failed just before it exited ends by its exit, with its log as written. When runs waited
    // with waitUntilExit(), which notices an exit up to about 60 ms after Foundation reaps the process, such a run was
    // stopped in that gap: a process that had exited was killed, and its whole log got a note saying the tests after
    // the failure did not run. The exit is now recorded as Foundation reaps the process (`TestRunEndingTests`).
    func test_whenTheLogShowsAFailedTestAfterTheProcessExited_thenTheRunIsNotStopped() async throws {
        // Written while the follower waits between reads.
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n\(failedRunSummary)\n", after: 0.05)])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(testProcess.terminateTreeCallCount, 0)
        // What a process that ended by itself left running, as a server a test left up, is its own business.
        XCTAssertEqual(testProcess.killProcessGroupCallCount, 0)
        XCTAssertFalse(result.testLog.contains("[SwiftMutator]"), result.testLog)
    }

    // A passing baseline printed a line shaped like a failed test, so a timed-out run showing it may only
    // have run the test that prints it.
    func test_whenFailedTestLinesAreUnreliable_thenATimedOutRunShowingOneTimesOut() async throws {
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n", after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let configuration = MuterConfiguration(
            executable: "/tmp/swift",
            arguments: ["test"],
            testSuiteTimeOut: 0.3,
            stopAtFirstFailure: true
        ).withUnreliableFailedTestLines()

        let result = try await runMutantsTests(on: testProcess, using: configuration)

        XCTAssertEqual(result.outcome, .timeout, result.testLog)
    }
}
