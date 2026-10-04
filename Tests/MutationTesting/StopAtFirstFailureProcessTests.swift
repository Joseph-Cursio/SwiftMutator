@testable import muterCore
import XCTest

/// These run real test commands, shell scripts that print what `swift test` prints, through the real
/// process factory and time limit, and kill every process they start however a test ends.
final class StopAtFirstFailureProcessTests: MuterTestCase {
    private let sut = MutationTestingDelegate()
    private var directory: URL!
    private let lock = NSLock()
    private var launched: [Foundation.Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try URL(fileURLWithPath: makeTemporaryDirectory())
        // Test logs are written to the current directory; keep them in the folder removed afterwards.
        fileManager.currentDirectoryPathToReturn = directory.path
        // Added after the folder's own teardown block, so it runs before that one.
        addTeardownBlock { [unowned self] in killEveryLaunchedProcess() }
    }

    func test_aRealTestCommandIsStoppedAtItsFirstFailedTestAndLeavesNothingRunning() async throws {
        // The sleep stands for the test runner `swift test` starts, and its odd length makes it easy to
        // find if it's left behind.
        let configuration = testCommand(running: """
            /bin/sleep 30.1717 & echo $! > child.pid
            echo "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed: 5 == 4"
            wait
            """)

        let started = Date()
        let result = try await runMutantsTests(using: configuration)

        XCTAssertEqual(result.outcome, .failed, result.testLog)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let child = try XCTUnwrap(pid(writtenTo: "child.pid"))
        XCTAssertTrue(waitUntil(within: 2) { isGone(child) }, "the test command's child is still running")
    }

    func test_aRealTestCommandThatPassesRunsToItsEnd() async throws {
        let summary = "✔ Test run with 1 test in 1 suite passed after 0.301 seconds."
        let configuration = testCommand(running: """
            echo "✔ Test sum() passed after 0.001 seconds."
            /bin/sleep 0.3
            echo "\(summary)"
            """)

        let started = Date()
        let result = try await runMutantsTests(using: configuration)

        XCTAssertEqual(result.outcome, .passed, result.testLog)
        XCTAssertTrue(result.testLog.contains(summary), result.testLog)
        XCTAssertFalse(result.testLog.contains("[SwiftMutator]"), result.testLog)
        // Well under the time limit: the run ends with its process, not when the time limit stops it.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the run outlived its process")
    }

    // MARK: - Helpers

    /// `/bin/sh` running `script` as a mutant's test command, which may stop at its first failed test.
    /// `buildSystem: swift` makes it stand for `swift test`, which adds `--skip-build`; sh takes that as `$0`.
    private func testCommand(running script: String) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/bin/sh",
            arguments: ["-c", script],
            testSuiteTimeOut: 60,
            buildSystem: .swift,
            stopAtFirstFailure: true
        )
    }

    /// Runs a mutant's tests with the real process factory and time limit, in this test's folder, as a
    /// parallel worker runs them in its clone.
    private func runMutantsTests(
        using configuration: MuterConfiguration
    ) async throws -> (outcome: TestSuiteOutcome, testLog: String) {
        current.process = { [unowned self] in
            let process = MuterProcessFactory.makeProcess()
            if let launchable = process as? Foundation.Process {
                lock.withLock { launched.append(launchable) }
            }
            return process
        }
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let schemata = try MutationSchema.make(
            filePath: "/path/fileName",
            position: .init(line: 1)
        )

        return await sut.runTestSuite(
            withSchemata: schemata,
            using: configuration,
            savingResultsIntoFileNamed: "logFileName",
            workingDirectory: directory
        )
    }

    /// Kills each launched process's process group until no process is left in it. Foundation.Process
    /// starts each launched process in a group of its own, and a shell's background jobs stay in it. A
    /// group found empty is never signalled again: the system may give its ID to another process.
    private func killEveryLaunchedProcess() {
        var groups = Set(lock.withLock { launched }.map(\.processIdentifier).filter { $0 > 1 }) // kill(-1) signals everything
        let groupsEmptied = waitUntil(within: 5) {
            groups = groups.filter { kill(-$0, SIGKILL) == 0 || errno != ESRCH }
            return groups.isEmpty
        }
        XCTAssertTrue(groupsEmptied, "processes are left in the process groups \(groups.sorted())")
    }

    private func pid(writtenTo name: String) -> Int32? {
        (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether no process has this ID.
    private func isGone(_ pid: Int32) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Polls `condition` until it holds or `timeout` seconds pass, and returns whether it held.
    private func waitUntil(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }
}
