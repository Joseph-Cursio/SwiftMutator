@testable import muterCore
import SwiftParser
import XCTest

/// The outcome rebuilt from a run's results file (`RecordedResults.mutationTestOutcome()`): for a finished run, the
/// outcome its own report was made from, so every format's report is the run's; for a stopped run, its partial one.
final class RecordedOutcomeTests: MuterTestCase {
    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.newVersion = "9.9.9"
        state.projectCoverage = .make(percent: 78, filesWithoutCoverage: ["/project_mutated/Sources/Untested.swift"])
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        // Discovery sorts files by path, and each file's mutants by line as a number, so the jobs are A/Util.swift:3,
        // B/Util.swift:3, B/Util.swift:12, Zeta.swift:9, Zeta.swift:10: not the order given here, and not the order
        // of their switch IDs, in which 12 comes before 3. Both Util.swift files share their switch IDs' file name.
        state.mutationMapping = try [
            makeMapping("/project_mutated/Sources/Zeta.swift", lines: [9, 10]),
            makeMapping("/project_mutated/Sources/B/Util.swift", lines: [3, 12]),
            makeMapping("/project_mutated/Sources/A/Util.swift", lines: [3]),
        ].mergeByFilePath()
    }

    // After setUpWithError, which XCTest calls first: MuterTestCase installs its fixed clock in both.
    override func setUp() {
        super.setUp()

        // Each mutant finishes at a time of its own, and the test duration isn't a whole number of milliseconds.
        let calls = Locked(0.0)
        current.now = {
            calls.change { count in
                count += 1
                return ResultsHeader.fixedStart.addingTimeInterval(count * 1.234567)
            }
        }
    }

    func test_theReportFromTheFile_equalsTheRunsReport_inEveryFormat_serially() async throws {
        try await assertTheReportFromTheFileEqualsTheRuns(workers: 1)
    }

    // The lines are written in the order the mutants finished in, which isn't the order they were tested in. The
    // timeout is tested again, and times out again.
    func test_theReportFromTheFile_equalsTheRunsReport_inEveryFormat_inParallel() async throws {
        try await assertTheReportFromTheFileEqualsTheRuns(workers: 2, rerun: (.timeout, "", .timedOut))
    }

    // The rerun's line follows the first run's timeout, and its kill, with the test that killed it, is what the file
    // reports, as the run did.
    func test_aTimeoutThatARerunKills_isReportedAsTheRunReportedIt() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        // The baseline, the worker clone's build, the five mutants, then the timeout's rerun.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .timeout, .passed, .failed, .failed]
        ioDelegate.mutantTestLogs = Array(repeating: "", count: 5)
            + ["✘ Test slow() recorded an issue at SlowTests.swift:4:5: Failed"]
        ioDelegate.mutantRunEndings = [.exited, .exited, .timedOut, .exited, .exited, .exited]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertFalse(runOutcome.mutations.contains { $0.testSuiteOutcome == .timeout })
        let slow = FailedTestLine.FailedTest(name: "slow()", location: "SlowTests.swift:4:5")
        XCTAssertEqual(
            runOutcome.mutations.compactMap(\.killingTests).filter { !$0.tests.isEmpty },
            [.init(tests: [slow], count: 1, isComplete: true)]
        )
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 6)
        XCTAssertEqual(records.last?.rerun, MutantResult.Rerun(because: "timeout", workers: 1))
        try assertTheResultsFileRebuilds(runOutcome)
    }

    // Suspect tests, and the score without them, come from each mutant's recorded tests, so a report made from the
    // file says what the run's own did, whatever order the lines come in.
    func test_aRunWithSuspectTests_reportsTheSameFromItsFile_inEveryFormat() async throws {
        state.mutationMapping = try (0 ..< 12).map { index in
            try makeMapping(String(format: "/project_mutated/Sources/F%02d.swift", index), lines: [3])
        }.mergeByFilePath()
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 1, suspectKillReruns: 0
        )
        // The baseline, then 11 kills and a survivor. Each kill's log names timing(), and the even ones' a focused
        // test too; the second run stopped at its first failed test.
        let timing = "✘ Test timing() recorded an issue at TimingTests.swift:9:5: Expectation failed: 1.2 < 1.0"
        let focused = { (index: Int) in
            "✘ Test focused\(index)() recorded an issue at F\(index)Tests.swift:3:5: Expectation failed"
        }
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 11) + [.passed]
        ioDelegate.mutantTestLogs = (0 ..< 11).map { index in
            index.isMultiple(of: 2) ? focused(index) + "\n" + timing : timing
        } + ["✔ Test run with 2 tests in 0 suites passed after 0.001 seconds."]
        ioDelegate.mutantRunEndings = [.exited, .stoppedAtFailedTest] + Array(repeating: .exited, count: 10)

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        let report = MuterTestReport(from: runOutcome)
        let summary = try XCTUnwrap(report.killingTestSummary)
        XCTAssertEqual(summary.filesWithKills, 11)
        XCTAssertEqual(summary.tests.filter(\.suspect).map(\.name), ["timing()"])
        XCTAssertEqual(summary.suspectOnlyKills, 5)
        XCTAssertEqual(summary.suspectOnlyKillsWithIncompleteLists, 1)
        XCTAssertEqual(report.globalMutationScore, 91)
        XCTAssertEqual(summary.mutationScoreWithoutSuspectOnlyKills, 50)
        XCTAssertTrue(
            PlainTextReporter().report(from: runOutcome)
                .contains("\nMutation Score without suspect tests: at least 50%\n")
        )
        XCTAssertTrue(XcodeReporter().report(from: runOutcome).contains("\nwarning: SwiftMutator: 1 test may fail"))
        try assertTheResultsFileRebuilds(runOutcome)
    }

    // What kills tested again alone came to is on their lines, so a report from the file says what the run's own did.
    func test_aRunThatTestedKillsAgainAlone_reportsTheSameFromItsFile_inEveryFormat() async throws {
        state.mutationMapping = try (0 ..< 4).map { index in
            try makeMapping("/project_mutated/Sources/F\(index).swift", lines: [3])
        }.mergeByFilePath()
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 1,
            suspectTestFilePercent: 50,
            suspectTestMinimumFiles: 2
        )
        let timing = "✘ Test timing() recorded an issue at TimingTests.swift:9:5: Expectation failed: 1.2 < 1"
        let sum = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed"
        let passed = "✔ Test run with 2 tests in 0 suites passed after 0.001 seconds."
        // The baseline, then kills in 3 of 4 files by timing(), and a survivor; then each kill alone: one fails again,
        // one passes, and one fails only by another test while timing() is shown passing.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .passed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [
            timing, timing, timing, passed, timing, passed, "✔ Test timing() passed after 0.1 seconds.\n" + sum,
        ]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        let report = MuterTestReport(from: runOutcome)
        let summary = try XCTUnwrap(report.killingTestSummary)
        XCTAssertEqual(summary.killsTestedAlone, 3)
        XCTAssertEqual(summary.killsThatSurvivedAlone, 1)
        XCTAssertEqual(report.globalMutationScore, 50)
        XCTAssertEqual(summary.flakyTests.map(\.name), ["timing()"])
        XCTAssertEqual(summary.flakyTests.first?.notReproducedAlone, 2)
        XCTAssertTrue(PlainTextReporter().report(from: runOutcome).contains("tested again, one at a time"))
        XCTAssertTrue(
            XcodeReporter().report(from: runOutcome).contains("didn't fail again often enough when tested alone")
        )
        try assertTheResultsFileRebuilds(runOutcome)
    }

    // The configuration's thresholds reach the run's report, and the header records them for the file's.
    func test_aRunsSuspectTestThresholds_reachItsReport_andTheReportFromItsFile() async throws {
        state.mutationMapping = try (0 ..< 4).map { index in
            try makeMapping("/project_mutated/Sources/F\(index).swift", lines: [3])
        }.mergeByFilePath()
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: 1,
            suspectTestFilePercent: 60,
            suspectTestMinimumFiles: 3,
            suspectKillReruns: 0
        )
        // timing() fails for the mutants in 3 of the 4 files, 75%; sum() for 1.
        let timing = "✘ Test timing() recorded an issue at TimingTests.swift:9:5: Expectation failed: 1.2 < 1.0"
        let sum = "✘ Test sum() recorded an issue at SumTests.swift:3:5: Expectation failed"
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .failed, count: 4)
        ioDelegate.mutantTestLogs = [timing, timing, timing, sum]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(runOutcome.suspectTestThresholds, SuspectTestThresholds(filePercent: 60, minimumFiles: 3))
        let summary = try XCTUnwrap(MuterTestReport(from: runOutcome).killingTestSummary)
        XCTAssertTrue(summary.suspectsChecked)
        XCTAssertEqual(summary.tests.filter(\.suspect).map(\.name), ["timing()"])
        XCTAssertEqual(summary.mutationScoreWithoutSuspectOnlyKills, 25)
        // The standard thresholds would give no verdict in 4 files.
        XCTAssertEqual(KillingTestSummary(of: runOutcome.mutations)?.suspectsChecked, false)
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.configuration.suspectTestFilePercent, 60)
        XCTAssertEqual(header.configuration.suspectTestMinimumFiles, 3)
        try assertTheResultsFileRebuilds(runOutcome)
    }

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

    // Each session's mutants are tested in the project as it was then, but reported where it is now.
    func test_pathsCoverageAndNewVersion_comeFromTheLatestHeader() throws {
        let jobs = fixtureJobs()
        let uncovered = ["/moved_mutated/Sources/Untested.swift"]

        let rebuilt = try rebuild(
            ResultsHeader.make(
                projectPath: "/project",
                mutatedProjectPath: "/project_mutated",
                coverage: CoverageSummary(percent: 50, filesWithoutCoverage: []),
                newVersion: ""
            ),
            mutantResult(jobs[0].schema, jobs[0].key),
            ResultsEnd.make(testDurationSeconds: 100.5, recorded: 1),
            ResultsHeader.make(
                session: 2,
                startedAt: ResultsHeader.fixedStart + 3_600,
                projectPath: "/moved",
                mutatedProjectPath: "/moved_mutated",
                coverage: CoverageSummary(percent: 78, filesWithoutCoverage: uncovered),
                newVersion: "9.9.9",
                configuration: MuterConfiguration(
                    executable: "/usr/bin/swift", arguments: ["test"], suspectTestFilePercent: 40
                )
            ),
            mutantResult(jobs[4].schema, jobs[4].key, outcome: .passed, session: 2),
            ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 1)
        )

        XCTAssertEqual(rebuilt.mutations, [
            mutation(jobs[0].schema, at: "/moved_mutated/Sources/A/Util.swift", outcome: .failed, project: "/moved"),
            mutation(jobs[4].schema, at: "/moved_mutated/Sources/Zeta.swift", outcome: .passed, project: "/moved"),
        ])
        XCTAssertEqual(rebuilt.mutations.map(\.originalProjectPath), [
            "/moved/Sources/A/Util.swift",
            "/moved/Sources/Zeta.swift",
        ])
        XCTAssertEqual(rebuilt.coverage, .make(percent: 78, filesWithoutCoverage: uncovered))
        XCTAssertEqual(rebuilt.newVersion, "9.9.9")
        XCTAssertEqual(rebuilt.testDuration, 120.75)
        XCTAssertEqual(rebuilt.suspectTestThresholds, SuspectTestThresholds(filePercent: 40, minimumFiles: 10))
    }

    // A resumed session discovers them again, so its header's replace the last session's, as every scope field does;
    // and none of them is a mutation, whose counts the reports show.
    func test_theMutantsOfCodeNoTestRan_comeFromTheLatestHeader_andAreNoMutation() throws {
        let jobs = fixtureJobs()
        let uncovered = { (line: Int) in
            UncoveredMutant(
                key: MutantKey(
                    path: "Sources/New.swift",
                    mutationOperatorId: .ror,
                    line: line,
                    column: 9,
                    occurrence: 0
                ),
                snapshot: .make(before: "<", after: ">")
            )
        }
        var first = ResultsHeader.make()
        first.mutantsNotCovered = [uncovered(4), uncovered(8)]
        var second = ResultsHeader.make(session: 2, startedAt: ResultsHeader.fixedStart + 3_600)
        second.mutantsNotCovered = [uncovered(8)]

        let rebuilt = try rebuild(
            first,
            mutantResult(jobs[0].schema, jobs[0].key),
            ResultsEnd.make(testDurationSeconds: 100.5, recorded: 1),
            second,
            ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 0)
        )

        XCTAssertEqual(rebuilt.uncoveredMutants, [uncovered(8)])
        XCTAssertEqual(rebuilt.mutations.count, 1)
        XCTAssertEqual(try rebuild(first, ResultsEnd.make(recorded: 0)).uncoveredMutants, [uncovered(4), uncovered(8)])
        XCTAssertEqual(try rebuild(ResultsHeader.make(), ResultsEnd.make(recorded: 0)).uncoveredMutants, [])
        // With coverage on, a header without them didn't record them, as an older SwiftMutator's: they aren't known,
        // and no baseline file is made of the results.
        let older = try rebuild(ResultsHeader.make(skipCoverage: false), ResultsEnd.make(recorded: 0))
        XCTAssertNil(older.uncoveredMutants)
        var whole = MutationTestOutcome()
        XCTAssertNil(whole.whyNoBaselineFile)
        whole.uncoveredMutants = older.uncoveredMutants
        XCTAssertEqual(whole.whyNoBaselineFile, MutationTestOutcome.uncoveredMutantsUnknown)
        var none = ResultsHeader.make(skipCoverage: false)
        none.mutantsNotCovered = []
        XCTAssertEqual(try rebuild(none, ResultsEnd.make(recorded: 0)).uncoveredMutants, [])
    }

    // A resumed session retires the results it doesn't stand by, and records again those it tests again.
    func test_aRetiredKey_isLeftOutOfTheReport() throws {
        let jobs = fixtureJobs()

        let rebuilt = try rebuild(
            ResultsHeader.make(),
            mutantResult(jobs[0].schema, jobs[0].key),
            mutantResult(jobs[1].schema, jobs[1].key),
            mutantResult(jobs[3].schema, jobs[3].key),
            ResultsEnd.make(reason: .interrupted, testDurationSeconds: 100.5, recorded: 3),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                startedAt: ResultsHeader.fixedStart + 3_600
            ),
            ResultsRetired(session: 2, keys: [jobs[1].key, jobs[3].key]),
            mutantResult(jobs[3].schema, jobs[3].key, outcome: .passed, session: 2),
            ResultsEnd.make(session: 2, testDurationSeconds: 20.25, recorded: 1)
        )

        XCTAssertEqual(rebuilt.mutations, [
            mutation(jobs[0].schema, at: "/project_mutated/Sources/A/Util.swift", outcome: .failed),
            mutation(jobs[3].schema, at: "/project_mutated/Sources/Zeta.swift", outcome: .passed),
        ])
        XCTAssertEqual(rebuilt.testDuration, 120.75)
    }

    // A stopped run's list may not name every test that failed, nor may a list that names fewer than were counted.
    func test_eachMutationsKillingTests_comeFromItsRecord() throws {
        let jobs = fixtureJobs()
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let total = FailedTestLine.FailedTest(name: "total()", location: "TotalTests.swift:8:5")

        let rebuilt = try rebuild(
            ResultsHeader.make(),
            mutantResult(jobs[2].schema, jobs[2].key, killedBy: [], failedTestCount: 0),
            mutantResult(jobs[1].schema, jobs[1].key, outcome: .passed),
            mutantResult(
                jobs[0].schema,
                jobs[0].key,
                killedBy: [sum, total],
                failedTestCount: 3,
                endedBy: .stoppedAtFailedTest
            )
        )

        XCTAssertEqual(rebuilt.mutations.map(\.killingTests), [
            MutationTestOutcome.KillingTests(tests: [sum, total], count: 3, isComplete: false),
            nil,
            .noneNamed,
        ])
    }

    func test_aRunWithoutCoverage_reportsNone() throws {
        let jobs = fixtureJobs()

        let rebuilt = try rebuild(
            ResultsHeader.make(coverage: nil, skipCoverage: false),
            mutantResult(jobs[0].schema, jobs[0].key)
        )

        XCTAssertEqual(rebuilt.mutations.map(label), ["/project_mutated/Sources/A/Util.swift:3"])
        XCTAssertEqual(rebuilt.coverage, .null)
        XCTAssertFalse(rebuilt.coverageSkipped)
        XCTAssertNil(MuterTestReport(from: rebuilt).projectCodeCoverage)
        let report = PlainTextReporter().report(from: rebuilt)
        XCTAssertTrue(report.contains("\nSwiftMutator could not gather coverage data from your project\n"), report)
        XCTAssertFalse(report.contains("Coverage skipped"), report)
    }

    // `--skip-coverage` leaves a run without coverage, as failing to gather it does, but neither its report nor the one
    // made from its file says SwiftMutator failed.
    func test_aRunThatSkippedCoverage_saysSo_asDoesTheReportFromItsFile() async throws {
        state.runOptions = .make(skipCoverage: true)
        state.projectCoverage = .null
        // The baseline, then the five mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .passed, .passed, .passed]

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(runOutcome)? = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertTrue(runOutcome.coverageSkipped)
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.skipCoverage), [true])
        let report = PlainTextReporter().report(from: runOutcome)
        XCTAssertTrue(report.contains("\nCoverage skipped (--skip-coverage)\n"), report)
        XCTAssertFalse(report.contains("could not gather coverage data"), report)
        try assertTheResultsFileRebuilds(runOutcome)
    }

    // Discovery sorts the absolute paths, so a file outside the mutated project keeps its place among them: here
    // after them, although its path, written as it is, sorts before theirs, written relative to the project.
    func test_aPathOutsideTheMutatedProject_staysAsItWas() throws {
        state.mutationMapping = try (state.mutationMapping + [
            makeMapping("/var/generated/Version.swift", lines: [4]),
        ]).mergeByFilePath()
        let jobs = fixtureJobs()
        let outside = try XCTUnwrap(jobs.last)
        XCTAssertEqual(outside.key.path, "/var/generated/Version.swift")

        let rebuilt = try rebuild(
            ResultsHeader.make(mutantsDiscovered: 6, mutantsToTest: 6),
            mutantResult(outside.schema, outside.key),
            mutantResult(jobs[0].schema, jobs[0].key)
        )

        XCTAssertEqual(rebuilt.mutations, [
            mutation(jobs[0].schema, at: "/project_mutated/Sources/A/Util.swift", outcome: .failed),
            mutation(outside.schema, at: "/var/generated/Version.swift", outcome: .failed),
        ])
    }
}

private extension RecordedOutcomeTests {
    /// Runs mutation testing on `workers` workers, then checks that the outcome rebuilt from its results file is its
    /// own, whatever order the mutants' lines come in.
    /// With more than one worker, the timeout is tested again, and its `rerun` comes to what it says.
    func assertTheReportFromTheFileEqualsTheRuns(
        workers: Int,
        rerun: (outcome: TestSuiteOutcome, log: String, ending: TestRun.Ending)? = nil,
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
            let expectedParsed = try JSONSerialization.jsonObject(with: Data(expectedReport.utf8)) as? [String: AnyHashable]
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

/// A guard on the order a results file's mutants are reported in: mutation testing's jobs, which discovery orders.
final class JobOrderTests: MuterTestCase {
    private let mutatedProject = URL(fileURLWithPath: "/project_mutated")
    /// Sources in memory, beside the two fixture files: a file whose mutants' lines order differently as text, and
    /// two files of one name.
    private let sources = [
        "/project_mutated/Sources/Zeta.swift": """
        struct Zeta {
            func check(_ value: Int, _ other: Int) -> Bool {
                // Padding, so that the mutants below
                // are on lines 9 to 11, which sort
                // differently as text and as numbers.
                //
                //
                //
                let first = value > 1
                let second = other < 2
                return first && second
            }
        }
        """,
        "/project_mutated/Sources/B/Util.swift": """
        struct Util {
            func isPositive(_ value: Int) -> Bool {
                value > 0
            }
        }
        """,
        "/project_mutated/Sources/A/Util.swift": """
        struct Util {
            func isSmall(_ value: Int) -> Bool {
                value < 10
            }
        }
        """,
    ]

    func test_sortingByJobOrder_givesDiscoverysOrder() async throws {
        let jobs = try await discoveredJobs()
        let keys = MutantKey.keys(for: jobs, under: mutatedProject)
        XCTAssertEqual(Set(jobs.map(\.filePath)).count, 5, "\(jobs.map(\.filePath))")
        let zetaLines = jobs
            .filter { $0.fileName == "Zeta.swift" && $0.mutationOperatorId == .ror }
            .map(\.position.line)
        XCTAssertEqual(zetaLines, [9, 9, 10, 10], "lines compare as numbers, not as the text of a switch ID")
        // In line order whatever the operator, not each operator's mutants in turn.
        for file in Set(jobs.map(\.filePath)) {
            let places = jobs.filter { $0.filePath == file }.map { [$0.position.line, $0.position.column] }
            XCTAssertEqual(places, places.sorted { $0.lexicographicallyPrecedes($1) }, file)
        }
        XCTAssertGreaterThan(Set(jobs.map(\.mutationOperatorId)).count, 1)
        let orders = zip(jobs, keys).map { job, key in
            JobOrder(filePath: job.filePath, inFile: job.orderInFile, occurrence: key.occurrence)
        }

        for shuffled in [Array(orders.reversed()), orders.shuffled(), orders.shuffled()] {
            XCTAssertEqual(shuffled.sorted(), orders)
        }

        // And so the outcome rebuilt from a results file that holds their records in any order.
        let encoder = ResultsCoding.encoder
        let records = try zip(jobs, keys).shuffled().map { try encoder.encode(mutantResult($0, $1)) }
        let file = try ([encoder.encode(ResultsHeader.make())] + records).reduce(Data()) { $0 + $1 + Data("\n".utf8) }
        let rebuilt = try RecordedResults.read(file, path: "/logs/results.jsonl")
            .mutationTestOutcome(resultsFile: "/logs/results.jsonl")
        XCTAssertEqual(rebuilt.mutations.map(\.point), jobs.map {
            MutationPoint(mutationOperatorId: $0.mutationOperatorId, filePath: $0.filePath, position: $0.position)
        })
    }

    // A resumed session keeps an earlier session's result as it was recorded, with an offset that counts the header
    // and import SwiftMutator inserted then. When the import gained an access level since, as another file of the
    // module did, the offset moved but the line and column didn't, and the run tested the two mutants at this place
    // by operator.
    func test_aKeptResultsOlderOffset_doesNotMoveIt() throws {
        let kept = MutantResult.make(line: 9, column: 5, utf8Offset: 120, mutationOperatorId: .swapTernary)
        let tested = MutantResult.make(
            session: 2,
            line: 9,
            column: 5,
            utf8Offset: 129,
            mutationOperatorId: .removeSideEffects
        )
        let encoder = ResultsCoding.encoder
        let lines: [any Encodable] = [ResultsHeader.make(), kept, ResultsHeader.make(session: 2), tested]
        let file = try lines.map { try encoder.encode($0) }.reduce(Data()) { $0 + $1 + Data("\n".utf8) }

        let rebuilt = try RecordedResults.read(file, path: "/logs/results.jsonl")
            .mutationTestOutcome(resultsFile: "/logs/results.jsonl")

        XCTAssertEqual(rebuilt.mutations.map(\.point.mutationOperatorId), [.removeSideEffects, .swapTernary])
    }

    /// The jobs mutation testing makes from what discovery finds in the fixture files and `sources`.
    private func discoveredJobs() async throws -> [MutationSchema] {
        let state = MutationTestState()
        state.mutationOperatorList = .allOperators
        state.sourceFileCandidates = [
            "\(fixturesDirectory)/sampleForDiscoveringMutations.swift",
            "\(fixturesDirectory)/sample With Spaces For Discovering Mutations.swift",
        ] + sources.keys.sorted()
        prepareCode.sourceCodeToReturn = { [sources] path in
            let source = sources[path].map { SourceCodeInfo(path: path, code: Parser.parse(source: $0)) }
                ?? muterCore.sourceCode(fromFileAt: path)
            return source.map { (source: $0, changes: .null) }
        }

        let changes = try await DiscoverMutationPoints().run(with: state)

        guard case let .mutationMappingsDiscovered(mappings)? = changes.first else {
            XCTFail("Expected mappings, got \(changes)")
            return []
        }
        return mappings.flatMap(\.mutationSchemata)
    }
}

/// A file in the mutated project at `path`, with a mutant on each of `lines`, at column 5.
private func makeMapping(_ path: String, lines: [Int]) throws -> SchemataMutationMapping {
    try SchemataMutationMapping.make(
        filePath: path,
        (
            source: "func bar() { }",
            schemata: lines.map { line in
                try .make(
                    filePath: path,
                    mutationOperatorId: .ror,
                    syntaxMutation: "",
                    position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                    // A description with a quote and a line break, which the file escapes.
                    snapshot: .make(before: ">", after: "<", description: "changed \"x > \(line)\"\nto \"x < \(line)\"")
                )
            }
        )
    )
}

/// The line mutation testing writes when the run of `schema`'s mutant, keyed `key`, ends in `outcome`, ended `endedBy`,
/// with `killedBy` failed, of `failedTestCount`.
private func mutantResult(
    _ schema: MutationSchema,
    _ key: MutantKey,
    outcome: TestSuiteOutcome = .failed,
    session: Int = 1,
    finishedAt: Date = ResultsHeader.fixedStart + 1,
    killedBy: [FailedTestLine.FailedTest]? = nil,
    failedTestCount: Int? = nil,
    endedBy: TestRun.Ending = .exited
) -> MutantResult {
    MutantResult(
        session: session,
        path: key.path,
        line: key.line,
        column: key.column,
        occurrence: key.occurrence,
        utf8Offset: schema.position.utf8Offset,
        mutationOperatorId: schema.mutationOperatorId,
        switchID: schema.id,
        snapshot: schema.snapshot,
        outcome: outcome,
        endedBy: endedBy,
        exitStatus: endedBy == .exited ? (outcome == .passed ? 0 : 1) : nil,
        durationSeconds: 1.5,
        worker: 0,
        finishedAt: finishedAt,
        killedBy: killedBy,
        failedTestCount: failedTestCount,
        firstFailedTestLine: nil,
        log: "",
        fileSHA256: nil
    )
}
