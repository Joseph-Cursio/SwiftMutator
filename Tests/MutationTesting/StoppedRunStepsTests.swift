@testable import muterCore
import XCTest

/// The steps of mutation testing a stopped run's record names, and the point after which a stop is the results file's.
final class StoppedRunStepsTests: MuterTestCase {
    private let state = MutationTestState()
    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, _ in [] }, removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.loggingDirectory = "/logs"
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 1
        )
        state.mutationMapping = try [
            SchemataMutationMapping.make(
                filePath: "/some/path",
                (
                    source: "func bar() { }",
                    schemata: [
                        .make(
                            filePath: "/tmp/project/file.swift",
                            mutationOperatorId: .ror,
                            syntaxMutation: "",
                            position: .firstPosition,
                            snapshot: .null
                        ),
                    ]
                )
            ),
        ]
    }

    // After `MuterTestCase.setUp()`, which makes the world anew, and as the handler does before the steps.
    override func setUp() {
        super.setUp()

        current.stoppedRun.start(at: Date(timeIntervalSince1970: 0), logDirectory: "/logs", testsMutants: true)
    }

    // A stop during the timed test run, which comes before the results, is recorded as one there.
    func test_aStopDuringTheTimedTestRun_isRecordedAsOne() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        ioDelegate.whileRunningTestsWithoutBuilding = { withUnsafeCurrentTask { $0?.cancel() } }

        _ = await sut.runInItsOwnTask(with: state)
        current.stoppedRun.record(.interrupted(signal: SIGINT), at: Date())

        XCTAssertEqual(try resultsFiles.records(ResultsStopped.self).map(\.step), [.timedTestRun])
    }

    // Once the results start, a stop is theirs: their end line says it, and no record of a stopped run is written.
    func test_aStopOnceTheResultsStarted_isNotRecordedAsAStoppedRun() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        ioDelegate.whileRunningMutant = { _ in withUnsafeCurrentTask { $0?.cancel() } }

        _ = await sut.runInItsOwnTask(with: state)

        XCTAssertNil(current.stoppedRun.record(.interrupted(signal: SIGINT), at: Date()))
        XCTAssertEqual(try resultsFiles.records(ResultsStopped.self), [])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).count, 1)
    }

    // A stop at once from the signal's thread, before the results, records it too.
    func test_aStopAtOnceBeforeTheResults_isRecorded() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let interruption = current.interruption
        ioDelegate.whileRunningBaseline = { _ in
            _ = interruption.record(SIGINT)
            interruption.stoppingAtOnce()
        }

        _ = await sut.runInItsOwnTask(with: state)

        let record = try XCTUnwrap(resultsFiles.records(ResultsStopped.self).first)
        XCTAssertEqual(record.step, .baseline)
        XCTAssertEqual(record.detail, "SIGINT")
    }
}

/// The steps after the baseline a stopped run names, and a stop at once while mutation testing cleans up.
final class StoppedRunWorkerStepsTests: MuterTestCase {
    private let state = MutationTestState()
    private let clone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var removing: (() -> Void)?
    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [clone] _, count in Array(repeating: clone, count: count) },
        removeWorkerDirectories: { [unowned self] _ in removing?() }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.loggingDirectory = "/logs"
        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...4).map { line in
            try SchemataMutationMapping.make(
                filePath: "/some/path",
                (
                    source: "func bar() { }",
                    schemata: [
                        .make(
                            filePath: "/tmp/project/file.swift",
                            mutationOperatorId: .ror,
                            syntaxMutation: "",
                            position: MutationPosition(utf8Offset: line, line: line, column: 0),
                            snapshot: .null
                        ),
                    ]
                )
            )
        }
    }

    override func setUp() {
        super.setUp()

        current.stoppedRun.start(at: Date(timeIntervalSince1970: 0), logDirectory: "/logs", testsMutants: true)
    }

    // A stop during the clones' baselines names them. A second signal while their clones are removed, which can take
    // seconds, stops the run at once, and still records it.
    func test_aStopAtOnceWhileTheClonesAreRemoved_recordsTheClonesBaselines() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        // The whole run, not the clone's own task.
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        ioDelegate.whileRunningBaseline = { worker in
            if worker == 1 { mutationTesting.cancel() }
        }
        let interruption = current.interruption
        removing = {
            _ = interruption.record(SIGINT)
            interruption.stoppingAtOnce()
        }

        _ = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        let record = try XCTUnwrap(resultsFiles.records(ResultsStopped.self).first)
        XCTAssertEqual(record.step, .workerBaselines)
        XCTAssertEqual(record.detail, "SIGINT")
    }
}
