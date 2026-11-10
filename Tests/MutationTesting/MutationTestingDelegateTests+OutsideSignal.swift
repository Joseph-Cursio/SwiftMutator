@testable import muterCore
import TestingExtensions
import XCTest

/// The waits a run asked for, in nanoseconds, recorded from any thread.
private final class Waits: @unchecked Sendable { // `list` is behind `lock`
    private let lock = NSLock()
    private var list: [UInt64] = []

    var all: [UInt64] { lock.withLock { list } }

    func append(_ nanoseconds: UInt64) {
        lock.withLock { list.append(nanoseconds) }
    }
}

/// How a test process ended, and whether a signal from outside may have ended it.
private struct ProcessEnding {
    let reason: Foundation.Process.TerminationReason
    let status: Int32
    let mayBe: Bool

    init(_ reason: Foundation.Process.TerminationReason, _ status: Int32, _ mayBe: Bool) {
        self.reason = reason
        self.status = status
        self.mayBe = mayBe
    }
}

extension MutationTestingDelegateTests {
    // MARK: - A run that a signal from outside ended

    // A signal from outside SwiftMutator (killall, logout, a supervisor stopping the whole tree) can end the test
    // command milliseconds before SwiftMutator's own signal stops mutation testing. Recorded at once, the run
    // counted as a crash, which kills the mutant. So such a run waits, and a stop that comes meanwhile cancels it.
    func test_aRunASignalEnded_isCancelled_whenMutationTestingStopsWithinTheWait() async throws {
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }
        let schemata = try MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1))
        // The wait lasts until the run is cancelled, and the test cancels it once the wait has begun. With the real
        // 0.25 s wait, a slow CI runner sometimes cancelled the run after the wait had ended.
        let waits = Waits()
        current.sleep = { nanoseconds in
            waits.append(nanoseconds)
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }

        for timeLimit in [nil, 60] as [TimeInterval?] {
            let testProcess = ScriptedProcessSpy([.dieOf(signal: SIGTERM, after: 0)])
            current.process = { testProcess }
            let configuration = MuterConfiguration(
                executable: "/tmp/swift",
                arguments: ["test"],
                testSuiteTimeOut: timeLimit
            )
            let waitsBefore = waits.all.count

            let run = Task { [sut] in
                await sut.runTestSuite(
                    withSchemata: schemata,
                    using: configuration,
                    savingResultsIntoFileNamed: "logFileName"
                )
            }
            let deadline = Date().addingTimeInterval(5)
            while waits.all.count == waitsBefore, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            run.cancel()
            let result = await run.value

            let description = "time limit: \(String(describing: timeLimit))"
            XCTAssertEqual(waits.all.count, waitsBefore + 1, "it didn't wait; \(description)")
            XCTAssertEqual(result.ending, .cancelled, description)
            XCTAssertNil(result.exitStatus, description)
            // The process had exited, and the system may have given its ID to another process.
            XCTAssertEqual(testProcess.terminateTreeCallCount, 0, description)
        }
        XCTAssertEqual(waits.all, Array(repeating: MutationTestingDelegate.outsideSignalWait, count: 2))
    }

    // The test above has a wait of its own. The real one ends as soon as its task is cancelled.
    func test_theRealWait_endsWhenItsTaskIsCancelled() async {
        let wait = Task { try await World().sleep(10_000_000_000) }
        wait.cancel()

        do {
            try await wait.value
            XCTFail("it ended without a CancellationError")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // Nothing stopped mutation testing, so the signal was meant for the tests alone: the run counts as before,
    // only later.
    func test_aRunASignalEnded_isRecordedAsBefore_whenNothingStopsIt() async throws {
        current.testingTimeOutExecutor = { TestingTimeoutExecutor() }

        for timeLimit in [nil, 60] as [TimeInterval?] {
            let testProcess = ScriptedProcessSpy([.dieOf(signal: SIGTERM, after: 0)])
            let configuration = MuterConfiguration(
                executable: "/tmp/swift",
                arguments: ["test"],
                testSuiteTimeOut: timeLimit
            )

            // The clock Task.sleep waits on.
            let started = DispatchTime.now()
            let result = try await runMutantsTests(on: testProcess, using: configuration)
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000

            let description = "time limit: \(String(describing: timeLimit))"
            XCTAssertEqual(result.ending, .exited, description)
            XCTAssertEqual(result.outcome, .runtimeError, description)
            XCTAssertEqual(result.exitStatus, SIGTERM, description)
            XCTAssertGreaterThanOrEqual(seconds, 0.25, description)
        }
    }

    // An ordinary test failure exits 1, and is recorded at once.
    func test_aRunThatExitedWithStatus1_doesNotWait() async throws {
        process.terminationStatus = 1

        let started = Date()
        let result = try await sut.runTestSuite(
            withSchemata: MutationSchema.make(filePath: "/path/fileName", position: .init(line: 1)),
            using: MuterConfiguration(executable: "/tmp/swift", arguments: ["test"], testSuiteTimeOut: 9),
            savingResultsIntoFileNamed: "logFileName"
        )

        XCTAssertEqual(result.ending, .exited)
        XCTAssertEqual(result.exitStatus, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
    }

    // SIGINT, SIGTERM and SIGHUP are what an outside stop sends. swiftly's proxy, and shells, pass a child's
    // signal on as an exit status: its number, or 128 + it. A crash, SwiftMutator's own SIGKILL and an ordinary
    // failure don't wait.
    func test_whichEndingsMayBeAnOutsideSignal() {
        let endings = [
            ProcessEnding(.uncaughtSignal, SIGINT, true),
            ProcessEnding(.uncaughtSignal, SIGTERM, true),
            ProcessEnding(.uncaughtSignal, SIGHUP, true),
            ProcessEnding(.uncaughtSignal, SIGKILL, false),
            ProcessEnding(.uncaughtSignal, SIGSEGV, false),
            ProcessEnding(.uncaughtSignal, SIGABRT, false),
            ProcessEnding(.exit, 2, true),
            ProcessEnding(.exit, 15, true),
            ProcessEnding(.exit, 129, true),
            ProcessEnding(.exit, 130, true),
            ProcessEnding(.exit, 143, true),
            ProcessEnding(.exit, 0, false),
            ProcessEnding(.exit, 1, false),
            ProcessEnding(.exit, 65, false),
        ]

        for ending in endings {
            XCTAssertEqual(
                MutationTestingDelegate.mayHaveEndedByAnOutsideSignal(
                    ProcessExit(status: ending.status, reason: ending.reason)
                ),
                ending.mayBe,
                "\(ending.reason == .exit ? "exit" : "signal") \(ending.status)"
            )
        }
    }
}
