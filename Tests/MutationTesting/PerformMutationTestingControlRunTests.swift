@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

/// Control runs: the test command with no mutant on, run among the mutants, whose failed tests are flaky.
final class PerformMutationTestingControlRunTests: MuterTestCase {
    private typealias Task = PerformMutationTesting.PoolTask

    private let state = MutationTestState()
    private let workerClone = URL(fileURLWithPath: "/project_mutated_worker1")
    private let timing = "✘ Test timing() recorded an issue at TimingTests.swift:9:5: Expectation failed: 1.2 < 1.0"
    private let sum = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { [workerClone] _, count in Array(repeating: workerClone, count: count) },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = configuration(controlRunEvery: 2)
        state.mutationMapping = try (1...4).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
    }

    // MARK: Where they go

    func test_tasks_putOneControlRunHalfwayThroughEachWholeStretch() {
        XCTAssertEqual(
            PerformMutationTesting.tasks(Array(0 ..< 250), controlRunEvery: 100)
                .enumerated()
                .compactMap { position, task in task == .control(1) || task == .control(2) ? position : nil },
            [50, 151]
        )
        XCTAssertEqual(PerformMutationTesting.tasks(Array(0 ..< 250), controlRunEvery: 100).count, 252)
        XCTAssertEqual(
            PerformMutationTesting.tasks([7, 8, 9, 10, 11], controlRunEvery: 2),
            [.mutant(7), .control(1), .mutant(8), .mutant(9), .control(2), .mutant(10), .mutant(11)]
        )
        XCTAssertEqual(
            PerformMutationTesting.tasks([4, 5], controlRunEvery: 1),
            [.control(1), .mutant(4), .control(2), .mutant(5)]
        )
        XCTAssertEqual(PerformMutationTesting.mutantsBefore(controlRun: 2, every: 100), 150)
    }

    func test_tasks_holdNoControlRun_withFewerMutantsThanAStretch_orWithNone() {
        XCTAssertEqual(
            PerformMutationTesting.tasks(Array(0 ..< 99), controlRunEvery: 100), (0 ..< 99).map(Task.mutant)
        )
        XCTAssertEqual(
            PerformMutationTesting.tasks([1, 2, 3], controlRunEvery: 0), [.mutant(1), .mutant(2), .mutant(3)]
        )
        XCTAssertEqual(PerformMutationTesting.tasks([], controlRunEvery: 1), [])
        XCTAssertEqual(MuterConfiguration().mutantsPerControlRun, 100)
        XCTAssertEqual(MuterConfiguration(controlRunEvery: 0).mutantsPerControlRun, 0)
    }

    // MARK: One worker

    func test_aRunsControlRuns_areRecordedAmongItsMutants_withTheirLogs() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .passed]
        let sent = recordEvents(named: [.controlRunFinished, .newMutationTestOutcomeAvailable])

        let changes = try await sut.run(with: state)

        XCTAssertEqual(
            try resultsFiles.kinds(),
            ["header", "mutant", "control", "mutant", "mutant", "control", "mutant", "end"]
        )
        let controls = try resultsFiles.records(ControlRunResult.self)
        XCTAssertEqual(controls.map(\.number), [1, 2])
        XCTAssertEqual(controls.map(\.afterMutants), [1, 3])
        XCTAssertEqual(controls.map(\.outcome), [.passed, .passed])
        XCTAssertEqual(controls.map(\.session), [1, 1])
        XCTAssertEqual(controls.map(\.worker), [0, 0])
        XCTAssertEqual(controls.map(\.log), ["control run 1.log", "control run 2.log"])
        XCTAssertEqual(controls.map(\.failedTests), [nil, nil])
        XCTAssertEqual(fileManager.createdFiles["/logs/control run 2.log"], Data("control run log".utf8))
        XCTAssertEqual(
            ioDelegate.keptOutputs.filter { $0.output.hasPrefix("/logs/running/control run") }.map(\.path),
            ["/logs/control run 1.log", "/logs/control run 2.log"]
        )
        // In the mutated project, with the mutants' configuration and time limit, and never counted as a mutant.
        XCTAssertEqual(ioDelegate.controlRunDirectories, [nil, nil])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(
            ioDelegate.controlRunConfigurations.map(\.testSuiteTimeout), [header.timeoutSeconds, header.timeoutSeconds]
        )
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [4])
        XCTAssertEqual(sent().map(\.name), [
            .newMutationTestOutcomeAvailable, .controlRunFinished, .newMutationTestOutcomeAvailable,
            .newMutationTestOutcomeAvailable, .controlRunFinished, .newMutationTestOutcomeAvailable,
        ])
        XCTAssertEqual((sent()[1].object as? ControlRunFinished)?.count, 2)
        let outcome = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(outcome.mutations.count, 4)
        XCTAssertEqual(outcome.controlRuns, Array(repeating: .init(outcome: .passed, failedTests: nil), count: 2))
    }

    // As a mutant's run does: the first run's log is kept from its text, beside the second's, which is recorded.
    func test_aControlRunTheSimulatorFailedToLaunch_runsOnceMore_andKeepsBothLogs() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], controlRunEvery: 2
        )
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.controlRuns = [(.failed, launchFailed)]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ControlRunResult.self).map(\.outcome), [.passed, .passed])
        XCTAssertEqual(fileManager.createdFiles["/logs/control run 1 (launch failed).log"], Data(launchFailed.utf8))
        XCTAssertEqual(fileManager.createdFiles["/logs/control run 1.log"], Data("control run log".utf8))
    }

    func test_noControlRun_whenTheKeyTurnsThemOff() async throws {
        state.muterConfiguration = configuration(controlRunEvery: 0)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed, .passed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ControlRunResult.self), [])
        XCTAssertEqual(ioDelegate.controlRunConfigurations, [])
    }

    // A test that fails with no mutant on is flaky: the kills only it failed for are suspect, however few files.
    func test_aTestThatFailsInAControlRun_isFlaky_andTheKillsOnlyItFailedFor_areSuspect() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [timing, timing + "\n" + sum, sum, "✔ Test run passed."]
        ioDelegate.controlRuns = [(.failed, timing), (.passed, "✔ Test run passed.")]
        let sent = recordEvents(named: [.controlRunFinished])

        let changes = try await sut.run(with: state)

        let controls = try resultsFiles.records(ControlRunResult.self)
        XCTAssertEqual(controls.map(\.outcome), [.failed, .passed])
        XCTAssertEqual(controls.first?.failedTests, [.init(name: "timing()", location: "TimingTests.swift:9:5")])
        XCTAssertEqual(controls.first?.failedTestCount, 1)
        XCTAssertEqual(controls.first?.firstFailedTestLine, timing)
        XCTAssertEqual((sent().first?.object as? ControlRunFinished)?.record, controls.first)

        let outcome = try XCTUnwrap(outcome(of: changes))
        let summary = try XCTUnwrap(MuterTestReport(from: outcome).killingTestSummary)
        XCTAssertEqual(summary.controlRuns, 2)
        XCTAssertEqual(summary.failedControlRuns, 1)
        XCTAssertEqual(summary.flakyTests, [.init(name: "timing()", file: "TimingTests.swift", controlRuns: 1)])
        // Too few files for the rule, but timing() is flaky.
        XCTAssertFalse(summary.suspectsChecked)
        XCTAssertEqual(summary.tests.map(\.name), ["sum()", "timing()"])
        XCTAssertEqual(summary.tests.map(\.suspect), [false, true])
        XCTAssertEqual(summary.tests.map(\.suspectCell), ["-", "flaky"])
        // The first mutant only timing() failed for; the second sum() failed for too.
        XCTAssertEqual(summary.suspectOnlyKills, 1)
        XCTAssertEqual(summary.mutationScoreWithoutSuspectOnlyKills, 50)
        XCTAssertEqual(
            KillingTestSummary.warning(for: outcome),
            "1 test may fail whatever the mutant: it failed in a control run, with no mutant on (timing() in 1 of 2). "
                + "Without its failures, the mutation score would be 50%, not 75%."
        )
    }

    // The baseline's lookalike lines name no flaky test, as they name no mutant's killing test.
    func test_aControlRunsFailedTests_leaveOutTheBaselinesLookalikes() async throws {
        let lookalike = "✘ Test parsesAFailure() recorded an issue at ParserTests.swift:3:5: printed by the test"
        ioDelegate.baselineTestLog = lookalike
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed]
        ioDelegate.controlRuns = [(.failed, lookalike + "\n" + timing), (.passed, lookalike)]

        _ = try await sut.run(with: state)

        let controls = try resultsFiles.records(ControlRunResult.self)
        XCTAssertEqual(controls.map(\.failedTests), [[.init(name: "timing()", location: "TimingTests.swift:9:5")], nil])
    }

    // MARK: Several workers

    func test_onSeveralSwiftPMWorkers_aControlRunRunsInTheFolderOfTheWorkerThatTookIt() async throws {
        state.muterConfiguration = configuration(controlRunEvery: 1, workers: 2)
        // The baseline, the worker clone's build, then the four mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 4)

        _ = try await sut.run(with: state)

        let controls = try resultsFiles.records(ControlRunResult.self)
        XCTAssertEqual(controls.map(\.number).sorted(), [1, 2, 3, 4])
        XCTAssertEqual(controls.map(\.afterMutants).sorted(), [0, 1, 2, 3])
        let folders = [URL(fileURLWithPath: "/project_mutated"), workerClone]
        XCTAssertEqual(ioDelegate.controlRunDirectories.count, 4)
        for (directory, worker) in zip(ioDelegate.controlRunDirectories, controls.map(\.worker)) {
            XCTAssertTrue(folders.contains(directory ?? URL(fileURLWithPath: "/")), "\(String(describing: directory))")
            XCTAssertTrue([0, 1].contains(worker))
        }
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 4)
    }

    // MARK: Reports from the file

    func test_theReportFromTheResultsFile_hasTheRunsControlRuns() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [timing, sum, sum, "✔ Test run passed."]
        ioDelegate.controlRuns = [(.timeout, ""), (.failed, timing)]

        let changes = try await sut.run(with: state)

        let data = Data((resultsFiles.lines.joined(separator: "\n") + "\n").utf8)
        let recorded = try RecordedResults.read(data, path: "/logs/results.jsonl")
        XCTAssertEqual(recorded.unreadableLines, [])
        XCTAssertEqual(recorded.controlRuns, try resultsFiles.records(ControlRunResult.self))
        let rebuilt = recorded.mutationTestOutcome(resultsFile: "/logs/results.jsonl")
        let outcome = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(rebuilt.controlRuns, outcome.controlRuns)
        XCTAssertEqual(rebuilt.controlRuns.map(\.outcome), [.timeout, .failed])
        XCTAssertEqual(
            PlainTextReporter().report(from: rebuilt),
            PlainTextReporter().report(from: outcome)
        )
        let summary = try XCTUnwrap(MuterTestReport(from: rebuilt).killingTestSummary)
        XCTAssertEqual(summary.failedControlRuns, 2)
        XCTAssertEqual(summary.failedControlRunsNamingNoTest, 1)
        XCTAssertEqual(summary.controlRunSentences, [
            "2 of the 2 control runs, with no mutant on and under the same load as the mutants, didn't pass.",
            "A test that failed in one is flaky, so it is suspect: timing() in 1.",
            "1 of them names no failed test, as a crash or a timeout may not.",
        ])
    }

    // A resumed run's file holds its earlier sessions' control runs, which its report counts; a reused run's doesn't.
    func test_aResumedRunsOutcome_countsTheEarlierSessionsControlRuns_butAReusedRunsDoesNot() throws {
        let earlier = ControlRunResult.make(
            outcome: .failed, worker: 2, failedTests: [.init(name: "timing()", location: "TimingTests.swift:9:5")]
        )
        let lines: [any Encodable] = [ResultsHeader.make(), earlier, ResultsEnd.make(recorded: 0)]
        let session = TestingSession(startedAt: ResultsHeader.fixedStart + 3_600, number: 2)
        session.controlRuns = [.make(session: 2, finishedAt: ResultsHeader.fixedStart + 3_700)]

        state.resumeState = try ResumeState.make(lines: lines, file: resultsFiles.openForResume(at: "/r.jsonl"))
        XCTAssertEqual(
            PerformMutationTesting.controlRuns(of: session, state: state).map(\.outcome), [.failed, .passed]
        )
        state.resumeState = try ResumeState.make(lines: lines, file: nil)
        XCTAssertEqual(PerformMutationTesting.controlRuns(of: session, state: state).map(\.outcome), [.passed])
    }

    // A reader that doesn't know the kind skips the line, as it would any later SwiftMutator's.
    func test_aControlLine_isAKindAnOlderReaderSkips() throws {
        let unknown = #"{"kind":"control","session":1}"#
        XCTAssertNoThrow(try ResultsCoding.decoder.decode(ResultsCoding.Kind.self, from: Data(unknown.utf8)))
        XCTAssertEqual(ControlRunResult.logName(of: 3), "control run 3.log")
    }

    // MARK: Helpers

    private func configuration(controlRunEvery: Int, workers: Int? = nil) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            mutationTestWorkers: workers,
            controlRunEvery: controlRunEvery,
            suspectKillReruns: 0
        )
    }

    private func outcome(of changes: [MutationTestState.Change]) -> MutationTestOutcome? {
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else { return nil }
        return outcome
    }

    private func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        for name in names {
            let observer = runEvents.observe(name) { sent.append($0) }
            addTeardownBlock { observer.cancel() }
        }
        return { sent }
    }

    private func makeSchemataMapping(file: String, line: Int) throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/project_mutated/\(file)",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/project_mutated/\(file)",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: MutationPosition(utf8Offset: line * 10, line: line, column: 5),
                        snapshot: .make(before: ">", after: "<", description: "changed > to <")
                    ),
                ]
            )
        )
    }
}
