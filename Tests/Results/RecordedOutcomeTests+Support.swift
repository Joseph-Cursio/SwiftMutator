@testable import muterCore
import XCTest

extension RecordedOutcomeTests {
    /// What a mutant tested again comes to: its outcome, its log and how its run ended.
    struct Rerun {
        let outcome: TestSuiteOutcome
        let log: String
        let ending: TestRun.Ending
    }

    /// Runs mutation testing on `workers` workers, then checks that the outcome rebuilt from its results file is its
    /// own, whatever order the mutants' lines come in.
    /// With more than one worker, the timeout is tested again, and its `rerun` comes to what it says.
    func assertTheReportFromTheFileEqualsTheRuns(
        workers: Int,
        rerun: Rerun? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: workers
        )
        // The baseline, each worker clone's build, then the five mutants. Each mutant's run takes its outcome, log
        // and ending together, whichever worker runs it.
        ioDelegate.testSuiteOutcomes = Array(repeating: .passed, count: workers)
            + [.failed, .passed, .runtimeError, .timeout, .buildError]
        ioDelegate.mutantTestLogs = [
            """
            ✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4
            ✘ Test total() recorded an issue at TotalTests.swift:8:5: Expectation failed
            """,
            "✔ Test run with 2 tests in 0 suites passed after 0.001 seconds.",
            "✘ Test sum() recorded an issue at SumTests.swift:12:5: Caught error\nFatal error: boom",
            "",
            "error: cannot convert value of type 'Bool' to expected argument type 'Int'",
        ]
        ioDelegate.mutantRunEndings = [.stoppedAtFailedTest, .exited, .exited, .timedOut, .exited]
        if let rerun {
            ioDelegate.testSuiteOutcomes.append(rerun.outcome)
            ioDelegate.mutantTestLogs.append(rerun.log)
            ioDelegate.mutantRunEndings.append(rerun.ending)
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)", file: file, line: line)
            return
        }
        XCTAssertEqual(runOutcome.mutations.count, 5, file: file, line: line)
        let killingTests = { (outcome: TestSuiteOutcome) in
            runOutcome.mutations.first { $0.testSuiteOutcome == outcome }?.killingTests
        }
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:12:5")
        let total = FailedTestLine.FailedTest(name: "total()", location: "TotalTests.swift:8:5")
        // The kill's run stopped, so its list may not be complete; the timeout's names no test.
        XCTAssertEqual(
            killingTests(.failed), .init(tests: [sum, total], count: 2, isComplete: false), file: file, line: line
        )
        XCTAssertEqual(
            killingTests(.runtimeError), .init(tests: [sum], count: 1, isComplete: true), file: file, line: line
        )
        XCTAssertEqual(killingTests(.timeout), .init(tests: [], count: 0, isComplete: false), file: file, line: line)
        XCTAssertNil(killingTests(.passed), file: file, line: line)
        XCTAssertNil(killingTests(.buildError), file: file, line: line)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [workers], file: file, line: line)
        XCTAssertEqual(try resultsFiles.kinds().last, "end", file: file, line: line)
        try assertTheResultsFileRebuilds(runOutcome, file: file, line: line)
        XCTAssertEqual(MuterTestReport(from: runOutcome).projectCodeCoverage, 78, file: file, line: line)
    }

    /// Checks that the outcome rebuilt from the results file the run wrote is `expected`, and so is every format's
    /// report of it, with the mutants' lines as written, reversed and rotated: they come in the order the mutants
    /// finished in, which can be any.
    func assertTheResultsFileRebuilds(
        _ expected: MutationTestOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // The end line must keep the test duration exactly, so it is one that rounding to the millisecond changes.
        XCTAssertGreaterThan(expected.testDuration, 0, file: file, line: line)
        XCTAssertNotEqual(
            (expected.testDuration * 1_000).rounded() / 1_000, expected.testDuration, file: file, line: line
        )
        freezeTheClock()
        let lines = resultsFiles.lines
        let orders = [
            ("as written", lines),
            ("reversed", reorderingMutantLines(lines) { $0.reversed() }),
            ("rotated", reorderingMutantLines(lines) { Array($0.dropFirst(2) + $0.prefix(2)) }),
        ]
        for (order, reordered) in orders {
            let rebuilt = try rebuild(from: reordered)
            XCTAssertEqual(rebuilt.mutations, expected.mutations, order, file: file, line: line)
            XCTAssertEqual(rebuilt.testDuration, expected.testDuration, order, file: file, line: line)
            XCTAssertEqual(rebuilt.newVersion, expected.newVersion, order, file: file, line: line)
            XCTAssertEqual(rebuilt.coverage, expected.coverage, order, file: file, line: line)
            XCTAssertEqual(rebuilt.coverageSkipped, expected.coverageSkipped, order, file: file, line: line)
            try assertEveryFormatsReport(of: rebuilt, equals: expected, order, file: file, line: line)
        }
    }

    func assertEveryFormatsReport(
        of rebuilt: MutationTestOutcome,
        equals expected: MutationTestOutcome,
        _ message: String,
        file: StaticString,
        line: UInt
    ) throws {
        for format in ReportFormat.allCases {
            let report = format.reporter.report(from: rebuilt)
            let expectedReport = format.reporter.report(from: expected)
            guard format == .json else {
                XCTAssertEqual(report, expectedReport, "\(format), \(message)", file: file, line: line)
                continue
            }
            // JSONEncoder promises no order of keys, so JSON compares parsed.
            let parsed = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: AnyHashable]
            let expectedParsed = try JSONSerialization.jsonObject(
                with: Data(expectedReport.utf8)
            ) as? [String: AnyHashable]
            XCTAssertNotNil(expectedParsed, message, file: file, line: line)
            XCTAssertEqual(parsed, expectedParsed, "\(format), \(message)", file: file, line: line)
        }
    }

    /// The HTML report's footer says when it was made, so both reports are made at one time.
    func freezeTheClock() {
        let frozen = current.now()
        current.now = { frozen }
    }

    /// `lines` with its mutants' lines, those between the header and the end line, put in another order, but each
    /// key's in the order written: a key's later line, such as a rerun's, replaces its earlier one.
    func reorderingMutantLines(_ lines: [String], _ reorder: ([String]) -> [String]) -> [String] {
        guard lines.count > 2, let header = lines.first, let end = lines.last else { return lines }
        let mutantLines = Array(lines.dropFirst().dropLast())
        let decoder = ResultsCoding.decoder
        let key = { (line: String) in
            (try? decoder.decode(MutantResult.self, from: Data(line.utf8)))?.key.description ?? line
        }
        var linesOfKey = Dictionary(grouping: mutantLines, by: key)
        let reordered = reorder(mutantLines).map { line in linesOfKey[key(line)]?.removeFirst() ?? line }
        return [header] + reordered + [end]
    }

    func rebuild(from lines: [String]) throws -> MutationTestOutcome {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        return try RecordedResults.read(data, path: "/logs/results.jsonl")
            .mutationTestOutcome(resultsFile: "/logs/results.jsonl")
    }

    func rebuild(_ records: any Encodable...) throws -> MutationTestOutcome {
        let encoder = ResultsCoding.encoder
        return try rebuild(from: records.map { String(lossyUTF8: try encoder.encode($0)) })
    }

    /// Each fixture job's schema and key, in job order.
    func fixtureJobs() -> [(schema: MutationSchema, key: MutantKey)] {
        let schemata = state.mutationMapping.flatMap(\.mutationSchemata)
        return Array(zip(schemata, MutantKey.keys(for: schemata, under: state.mutatedProjectDirectoryURL)))
    }

    /// The mutation a run of `project` reports for `schema`'s mutant at `filePath`, in `project`'s mutated copy.
    func mutation(
        _ schema: MutationSchema,
        at filePath: String,
        outcome: TestSuiteOutcome,
        project: String = "/project",
        killingTests: MutationTestOutcome.KillingTests? = nil
    ) -> MutationTestOutcome.Mutation {
        MutationTestOutcome.Mutation(
            testSuiteOutcome: outcome,
            mutationPoint: MutationPoint(
                mutationOperatorId: schema.mutationOperatorId,
                filePath: filePath,
                position: schema.position
            ),
            mutationSnapshot: schema.snapshot,
            originalProjectDirectoryUrl: URL(fileURLWithPath: project),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: project + "_mutated"),
            killingTests: killingTests,
            reusedFrom: nil,
            // As `mutantResult` records them.
            key: MutantKey(
                path: RepoRelativePath.of(filePath, under: URL(fileURLWithPath: project + "_mutated")),
                mutationOperatorId: schema.mutationOperatorId,
                line: schema.position.line,
                column: schema.position.column,
                occurrence: 0
            ),
            durationSeconds: 1.5
        )
    }

    func label(_ mutation: MutationTestOutcome.Mutation) -> String {
        "\(mutation.point.filePath):\(mutation.point.position.line)"
    }

    /// Every early end sent from now on, in order.
    func recordEarlyEnds() -> () -> [EarlyEnd] {
        var earlyEnds: [EarlyEnd] = []
        let observer = runEvents.observe(.mutationTestingEndedEarly) {
            if let earlyEnd = $0.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }
        addTeardownBlock { observer.cancel() }
        return { earlyEnds }
    }
}
