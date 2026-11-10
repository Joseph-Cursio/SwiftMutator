@testable import muterCore
import TestingExtensions
import XCTest

extension MutationTestingDelegateTests {
    // MARK: - How a run ended

    func test_aRunThatEndsByItself_endsExited_withItsExitStatus() async throws {
        process.terminationStatus = 3

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .runtimeError)
        XCTAssertEqual(result.ending, .exited)
        XCTAssertEqual(result.exitStatus, process.terminationStatus)
    }

    // A run SwiftMutator stopped exits with the status of its SIGKILL, which says nothing about the mutant.
    func test_aRunStoppedAtItsTimeLimit_endsTimedOut_withoutExitStatus() async throws {
        testingTimeOutExecutor.shouldSucceed = false
        process.terminationStatus = SIGKILL

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertNil(result.exitStatus)
    }

    func test_aRunStoppedAtItsFirstFailedTest_endsStoppedAtFailedTest_withoutExitStatus() async throws {
        let testProcess = ScriptedProcessSpy([.write("\(failedTestLine)\n", after: 0), .runUntilKilled])
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        let result = try await runMutantsTests(on: testProcess, using: stoppingConfiguration)

        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.ending, .stoppedAtFailedTest)
        XCTAssertEqual(testProcess.terminationStatus, SIGKILL)
        XCTAssertNil(result.exitStatus)
    }

    // Whoever cancels a run doesn't use its outcome, which stays a build error, and its ending says so. With a
    // time limit, the CancellationError can come from the time limit's task rather than from the run's ending.
    func test_aCancelledRun_endsCancelled_andIsStillABuildError() async throws {
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))

        for timeLimit in [nil, 60] as [TimeInterval?] {
            // Gives up after 5 seconds, so the run ends even if cancelling it doesn't kill its process.
            let testProcess = ScriptedProcessSpy([.runUntilKilled])
            current.process = { testProcess }
            let configuration = MuterConfiguration(
                executable: "/tmp/swift",
                arguments: ["test"],
                testSuiteTimeOut: timeLimit
            )

            let run = Task { [sut] in
                await sut.runTestSuite(
                    withSchemata: schemata,
                    using: configuration,
                    savingResultsIntoFileNamed: "logFileName"
                )
            }
            let deadline = Date().addingTimeInterval(5)
            while !testProcess.hasStarted, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            run.cancel()
            let result = await run.value

            let description = "time limit: \(String(describing: timeLimit))"
            XCTAssertEqual(result.ending, .cancelled, description)
            XCTAssertEqual(result.outcome, .buildError, description)
            XCTAssertNil(result.exitStatus, description)
        }
    }

    func test_aCommandThatCannotStart_endsCouldNotRun_withTheSameMessage() async throws {
        process.runError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The file \"swift\" doesn't exist."]
        )

        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "swift", arguments: ["test", "--filter", "CalcTests"]),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.outcome, .buildError)
        XCTAssertEqual(result.ending, .couldNotRun)
        XCTAssertNil(result.exitStatus)
        XCTAssertEqual(result.testLog, """
            SwiftMutator could not run your test command and captured no test output.

              executable: swift
              arguments: test --filter CalcTests
              working directory: \(outputFolder)

            The file "swift" doesn't exist.
            """)
    }
}
