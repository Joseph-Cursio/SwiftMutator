@testable import muterCore
import XCTest

/// The outcome rebuilt from a run's results file (`RecordedResults.mutationTestOutcome()`): for a finished run, the
/// outcome its own report was made from, so every format's report is the run's; for a stopped run, its partial one.
final class RecordedOutcomeTests: MuterTestCase, RecordedOutcomeTesting {
    let state = MutationTestState()
    let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")

    lazy var sut = PerformMutationTesting(
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
        try await assertTheReportFromTheFileEqualsTheRuns(
            workers: 2,
            rerun: Rerun(outcome: .timeout, log: "", ending: .timedOut)
        )
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
        state.mutationMapping = try (0 ..< 12)
            .map { index in
                try makeMapping(String(format: "/project_mutated/Sources/F%02d.swift", index), lines: [3])
            }
            .mergeByFilePath()
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
        state.mutationMapping = try (0 ..< 4)
            .map { index in
                try makeMapping("/project_mutated/Sources/F\(index).swift", lines: [3])
            }
            .mergeByFilePath()
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
        state.mutationMapping = try (0 ..< 4)
            .map { index in
                try makeMapping("/project_mutated/Sources/F\(index).swift", lines: [3])
            }
            .mergeByFilePath()
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
}
