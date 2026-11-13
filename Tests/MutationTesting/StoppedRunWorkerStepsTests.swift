@testable import muterCore
import XCTest

/// The steps after the baseline a stopped run names, and a stop at once while mutation testing cleans up.
final class StoppedRunWorkerStepsTests: MuterTestCase {
    private let state = MutationTestState()
    private let clone = URL(fileURLWithPath: "/project_mutated_worker1")
    private var removing: (() -> Void)?
    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [clone] _, count in Array(repeating: clone, count: count) },
        removeWorkerDirectories: { [weak self] _ in self?.removing?() }
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
                ),
                filePath: "/some/path"
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
