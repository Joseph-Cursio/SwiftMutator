@testable import muterCore
import XCTest

extension RecordedOutcomeTests {
    func test_recordsInCompletionOrder_areReportedInJobOrder() throws {
        let jobs = fixtureJobs()
        // Each repeat of a place and operator comes in the order it was found, which its occurrence numbers.
        let repeated = try makeMapping("/project_mutated/Sources/Zeta.swift", lines: [9]).mutationSchemata
        let repeatKey = MutantKey(
            path: "Sources/Zeta.swift",
            mutationOperatorId: .ror,
            line: 9,
            column: 5,
            occurrence: 1
        )
        let records = jobs.map { mutantResult($0.schema, $0.key) }

        let rebuilt = try rebuild(
            ResultsHeader.make(mutantsDiscovered: 6, mutantsToTest: 6),
            mutantResult(try XCTUnwrap(repeated.first), repeatKey, outcome: .passed),
            records[4],
            records[1],
            records[3],
            records[0],
            records[2]
        )

        XCTAssertEqual(rebuilt.mutations.map(label), [
            "/project_mutated/Sources/A/Util.swift:3",
            "/project_mutated/Sources/B/Util.swift:3",
            "/project_mutated/Sources/B/Util.swift:12",
            "/project_mutated/Sources/Zeta.swift:9",
            "/project_mutated/Sources/Zeta.swift:9",
            "/project_mutated/Sources/Zeta.swift:10",
        ])
        XCTAssertEqual(
            rebuilt.mutations.map(\.testSuiteOutcome),
            [.failed, .failed, .failed, .failed, .passed, .failed]
        )
    }

    func test_theReportFromAnAbortedRunsFile_equalsItsPartialReport() async throws {
        state.mutationMapping = try (state.mutationMapping + [
            makeMapping("/project_mutated/Sources/Omega.swift", lines: [1, 2, 3]),
        ]).mergeByFilePath()
        // Eight jobs: the fifth build error in a row stops the run after the seventh.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed] + Array(repeating: .buildError, count: 5)
        let earlyEnds = recordEarlyEnds()

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )

        let earlyEnd = try XCTUnwrap(earlyEnds().first)
        XCTAssertEqual(earlyEnd.reason, .aborted)
        XCTAssertEqual(earlyEnd.outcome.mutations.count, 7)
        XCTAssertEqual(earlyEnd.discovered, 8)
        try assertTheResultsFileRebuilds(earlyEnd.outcome)
    }

    func test_theReportFromAnInterruptedRunsFile_equalsItsPartialReport() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantRunEndings = [.exited, .exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let earlyEnds = recordEarlyEnds()

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let earlyEnd = try XCTUnwrap(earlyEnds().first)
        XCTAssertEqual(earlyEnd.reason, .interrupted)
        XCTAssertEqual(earlyEnd.outcome.mutations.count, 2)
        try assertTheResultsFileRebuilds(earlyEnd.outcome)
    }

    // A stopped run's partial report says it skipped coverage, as a finished run's report does.
    func test_thePartialReportOfARunThatSkippedCoverage_saysSo() async throws {
        state.runOptions = .make(skipCoverage: true)
        state.projectCoverage = .null
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantRunEndings = [.exited, .exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let earlyEnds = recordEarlyEnds()

        _ = await sut.runInItsOwnTask(with: state)

        let earlyEnd = try XCTUnwrap(earlyEnds().first)
        XCTAssertTrue(earlyEnd.outcome.coverageSkipped)
        let report = PlainTextReporter().report(from: earlyEnd.outcome)
        XCTAssertTrue(report.contains("\nCoverage skipped (--skip-coverage)\n"), report)
        try assertTheResultsFileRebuilds(earlyEnd.outcome)
    }

    // A run that was killed, or crashed, or is still running.
    func test_aFileWithoutAnEndLine_reportsItsMutants_overTheTimeToTheLastOne() throws {
        let jobs = fixtureJobs()

        let rebuilt = try rebuild(
            ResultsHeader.make(),
            mutantResult(jobs[3].schema, jobs[3].key, finishedAt: ResultsHeader.fixedStart + 62.5),
            mutantResult(jobs[0].schema, jobs[0].key, finishedAt: ResultsHeader.fixedStart + 31.25)
        )

        XCTAssertEqual(rebuilt.mutations.map(label), [
            "/project_mutated/Sources/A/Util.swift:3",
            "/project_mutated/Sources/Zeta.swift:9",
        ])
        XCTAssertEqual(rebuilt.testDuration, 62.5)
    }
}
