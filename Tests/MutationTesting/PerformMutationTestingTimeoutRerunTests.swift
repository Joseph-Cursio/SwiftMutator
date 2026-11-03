@testable import muterCore
import TestingExtensions
import XCTest

/// The timeouts of mutants tested on more than one worker, tested again once the others are, on a quarter of the
/// workers and under the same limit.
final class PerformMutationTestingTimeoutRerunTests: MuterTestCase {
    private let state = MutationTestState()

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, count in (0 ..< count).map { Self.clone($0 + 1) } },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4
        )
        state.mutationMapping = try [makeSchemataMapping(lines: Array(1...4))]
    }

    // At 4 workers, one: the mutated project's, which every run left free. Its line follows the first run's, with a
    // log of its own, and its kill is the mutant's outcome.
    func test_aTimeout_isRunAgainOnce_underTheSameLimit_afterTheOthers() async throws {
        // The baseline, the three clones' builds, the four mutants, then the timeout's rerun.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .passed, .failed, .timeout, .passed, .failed]
            + [.failed]
        let sent = recordEvents(named: [
            .newMutationTestOutcomeAvailable, .newTestLogAvailable, .timeoutRerunsStarted, .timeoutRerunFinished,
            .timeoutRerunsFinished,
        ])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.count, 5)
        XCTAssertEqual(Set(ioDelegate.configurations.map(\.testSuiteTimeout)).count, 1, "one limit for every run")
        XCTAssertEqual(ioDelegate.workingDirectories.last, state.mutatedProjectDirectoryURL)
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 5)
        let timeout = try XCTUnwrap(records.first { $0.outcome == .timeout })
        let rerun = try XCTUnwrap(records.last)
        XCTAssertEqual(rerun.key, timeout.key)
        XCTAssertEqual(records.filter { $0.key == timeout.key }, [timeout, rerun])
        XCTAssertNil(timeout.rerun)
        XCTAssertEqual(rerun.rerun, MutantResult.Rerun(because: "timeout", workers: 1))
        XCTAssertEqual(rerun.outcome, .failed)
        XCTAssertEqual(timeout.log, MutationTestLog.keptFileName(for: timeout.key))
        XCTAssertEqual(rerun.log, MutationTestLog.rerunFileName(for: timeout.key))
        XCTAssertEqual(
            ioDelegate.testLogs.last,
            "/logs/running/\(timeout.line - 1)_rerun_Sum.swift_RelationalOperatorReplacement_\(timeout.line * 10)"
                + "_\(timeout.line)_5.log"
        )
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [5])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertFalse(outcome.mutations.contains { $0.testSuiteOutcome == .timeout })
        XCTAssertEqual(outcome.mutations.count, 4)

        // The progress counts each mutant once: four outcomes, and the baseline's log with the four mutants'.
        let names = sent().map(\.name)
        XCTAssertEqual(names.filter { $0 == .newMutationTestOutcomeAvailable }.count, 4)
        XCTAssertEqual(names.filter { $0 == .newTestLogAvailable }.count, 5)
        XCTAssertEqual(
            Array(names.suffix(3)),
            [.timeoutRerunsStarted, .timeoutRerunFinished, .timeoutRerunsFinished]
        )
        let reruns = try XCTUnwrap(sent().compactMap { $0.object as? TimeoutReruns }.first)
        XCTAssertEqual(reruns.count, 1)
        XCTAssertEqual(reruns.workers, 1)
        XCTAssertEqual(reruns.limitSeconds, ioDelegate.configurations.first?.testSuiteTimeout)
        let finished = try XCTUnwrap(sent().compactMap { $0.object as? TimeoutRerun }.first)
        XCTAssertEqual(finished.rerun.testSuiteOutcome, .failed)
        XCTAssertEqual(finished.log.keptFileName, rerun.log)
        XCTAssertEqual([finished.number, finished.count], [1, 1])
        XCTAssertTrue(finished.changed)
        let tally = try XCTUnwrap(sent().compactMap { $0.object as? TimeoutRerunTally }.first)
        XCTAssertEqual([tally.rerun, tally.killed, tally.changed], [1, 1, 1])
    }

    // A mutant that loops forever loops again: it stays a timeout, which the score counts as a survivor.
    func test_aTimeoutAgain_staysATimeout() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .passed, .failed, .timeout, .passed, .failed]
            + [.timeout]
        var tallies: [TimeoutRerunTally] = []
        whenSent(.timeoutRerunsFinished) { ($0.object as? TimeoutRerunTally).map { tallies.append($0) } }

        let changes = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.outcome).filter { $0 == .timeout }.count, 2)
        XCTAssertNotNil(records.last?.rerun)
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            return XCTFail("Expected an outcome, got \(changes)")
        }
        XCTAssertEqual(outcome.mutations.filter { $0.testSuiteOutcome == .timeout }.count, 1)
        XCTAssertEqual(tallies.map(\.timedOutAgain), [1])
        XCTAssertEqual(tallies.map(\.changed), [0])
    }

    func test_withoutTimeouts_nothingIsRunAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed, .passed, .failed, .passed, .passed, .failed]
        let sent = recordEvents(named: [.timeoutRerunsStarted, .timeoutRerunFinished, .timeoutRerunsFinished])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.count, 4)
        XCTAssertEqual(sent().count, 0)
        XCTAssertTrue(try resultsFiles.records(MutantResult.self).allSatisfy { $0.rerun == nil })
    }

    // One worker is as low a load as there is, so another run would test under the same.
    func test_oneWorker_neverRunsATimeoutAgain() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .timeout, .passed, .failed]
        let sent = recordEvents(named: [.timeoutRerunsStarted])

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.count, 4)
        XCTAssertEqual(sent().count, 0)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 4)
    }

    // Five timeouts that fail to build when run again say nothing of five mutants in a row: the run finishes.
    func test_rerunBuildErrors_dontCountTowardTheAbort() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try [makeSchemataMapping(lines: Array(1...5))]
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .timeout, count: 5)
            + Array(repeating: .buildError, count: 5)

        _ = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.filter { $0.rerun != nil }.map(\.outcome), Array(repeating: .buildError, count: 5))
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.reason), [.finished])
    }

    // A worker's active-mutant file switches on one mutant at a time. At 8 workers, two rerun at once, in the mutated
    // project and the first clone.
    func test_aDirectoryNeverHasTwoRunsAtOnce() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 8
        )
        state.mutationMapping = try [makeSchemataMapping(lines: Array(1...8))]
        ioDelegate.testSuiteOutcomes = Array(repeating: .passed, count: 8) + Array(repeating: .timeout, count: 8)
            + Array(repeating: .passed, count: 8)
        // Each run takes a moment, so the reruns overlap.
        ioDelegate.whileRunningMutant = { _ in usleep(2000) }
        var started: [TimeoutReruns] = []
        whenSent(.timeoutRerunsStarted) { ($0.object as? TimeoutReruns).map { started.append($0) } }

        _ = try await sut.run(with: state)

        XCTAssertEqual(started.map(\.workers), [2])
        XCTAssertEqual(ioDelegate.directoriesSharedAtOnce, [])
        XCTAssertEqual(
            Set(ioDelegate.workingDirectories.suffix(8)),
            [state.mutatedProjectDirectoryURL, Self.clone(1)]
        )
        let reruns = try resultsFiles.records(MutantResult.self).filter { $0.rerun != nil }
        XCTAssertEqual(Set(reruns.map(\.key)).count, 8)
        XCTAssertEqual(Set(reruns.map(\.rerun?.workers)), [2])
    }

    // A stop kills the rerun under way, which isn't recorded. The file keeps every first run's line and the rerun
    // that finished, and the early end reports its kill, and the other's timeout.
    func test_aStopDuringTheReruns_keepsTheFinishedOnes() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try [makeSchemataMapping(lines: Array(1...3))]
        // The baseline, the clone's build, the three mutants, then the two reruns, one at a time.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .timeout, .timeout, .failed, .failed, .failed]
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        ioDelegate.whileRunningMutant = { number in
            if number == 4 { mutationTesting.cancel() }
        }
        var earlyEnds: [EarlyEnd] = []
        whenSent(.mutationTestingEndedEarly) { ($0.object as? EarlyEnd).map { earlyEnds.append($0) } }

        let result = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.filter { $0.rerun != nil }.map(\.line), [1])
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(end.recorded, 4)
        XCTAssertEqual(earlyEnds.first?.outcome.mutations.map(\.testSuiteOutcome), [.failed, .timeout, .failed])
    }

    private static func clone(_ worker: Int) -> URL {
        URL(fileURLWithPath: "/project_mutated_worker\(worker)")
    }

    /// The events sent with any of `names` so far, in order.
    private func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        let observer = runEvents.observe { event in
            if names.contains(event.name) { sent.append(event) }
        }
        addTeardownBlock { observer.cancel() }
        return { sent }
    }

    /// Calls `handler` with each event sent with `name`, from the task that sends it, until the test ends.
    private func whenSent(_ name: RunEvent.Name, _ handler: @escaping (RunEvent) -> Void) {
        let observer = runEvents.observe(name, handler)
        addTeardownBlock { observer.cancel() }
    }

    /// Sum.swift in the mutated project, with a mutant at each of `lines`, column 5.
    private func makeSchemataMapping(lines: [Int]) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/Sources/Sum.swift",
            (
                source: "func bar() { }",
                schemata: lines.map { line in
                    try .make(
                        filePath: "/project_mutated/Sources/Sum.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    )
                }
            )
        )
    }
}
