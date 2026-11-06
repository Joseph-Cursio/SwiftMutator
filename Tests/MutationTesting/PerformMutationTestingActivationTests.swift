@testable import muterCore
import TestingExtensions
import XCTest

/// What a run does with whether each mutant's block ran (`TestRun.activated`): a survivor whose block didn't is not
/// covered, a kill whose block didn't is tested again, and a run that shows nothing either way leaves every verdict as
/// it was, or stops, where it should have shown something.
final class PerformMutationTestingActivationTests: MuterTestCase {
    private static let path = "Sources/Sum.swift"
    private static let hash = "ab12"
    private let state = MutationTestState()

    private lazy var sut = PerformMutationTesting(
        makeWorkerDirectories: { _, count in
            (0 ..< count).map { URL(fileURLWithPath: "/project_mutated_worker\($0 + 1)") }
        },
        removeWorkerDirectories: { _ in }
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        state.projectDirectoryURL = URL(fileURLWithPath: "/project")
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: "/project_mutated")
        state.loggingDirectory = "/logs"
        state.muterConfiguration = swiftTest(workers: 1)
        state.mutationMapping = try [makeMapping(lines: Array(1...2))]
        let files = [Self.path: Self.hash]
        state.projectTree = ProjectTree(
            listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files)
        )
    }

    // MARK: - Survivors

    // The line keeps the run's own outcome, which reads as a survivor to anything older, and says its block didn't run.
    func test_aSurvivorWhoseBlockDidntRun_isNotCovered_andItsLineStillSaysItPassed() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed]
        ioDelegate.mutantActivations = [false, true]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.noCoverage, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [false, true])
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.outcome), [.passed, .passed])
        XCTAssertEqual(records.map(\.activated), [false, true])
    }

    // Both count alike in the score, which is #89's to change.
    func test_aMutantNotCovered_countsInTheScoreAsASurvivorDoes() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantActivations = [true, false]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .noCoverage])
        XCTAssertEqual(MuterTestReport(from: outcome).globalMutationScore, 50)
    }

    func test_aSurvivorThatShowsNothing_staysASurvivor_andItsLineSaysNothing() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .passed]
        ioDelegate.mutantActivations = [nil, true]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .passed])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.activated), [nil, true])
    }

    func test_theResultsFile_readsAsTheRunReportedIt() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed]
        ioDelegate.mutantActivations = [false, true]

        let outcome = try await run()

        let recorded = try RecordedResults.read(Data(resultsFiles.lines.joined(separator: "\n").utf8), path: "/logs/r")
            .mutationTestOutcome(resultsFile: "/logs/r")
        XCTAssertEqual(recorded.mutations.map(\.testSuiteOutcome), outcome.mutations.map(\.testSuiteOutcome))
        XCTAssertEqual(recorded.mutations.map(\.activated), outcome.mutations.map(\.activated))
    }

    // MARK: - Kills that didn't run their code

    // A flaky test, say: with the mutant's block not run, its tests pass this time.
    func test_aKillWhoseBlockDidntRun_isTestedAgain_andWhatThatShowsStands() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .passed]
        ioDelegate.mutantActivations = [false, true, false]
        let sent = recordEvents(named: [.newMutationTestOutcomeAvailable, .unprovenRunsRerunStarted, .unprovenRunRerun])

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.noCoverage, .passed])
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.last?.key, records.first?.key)
        XCTAssertEqual(
            records.last?.rerun,
            MutantResult.Rerun(because: MutantResult.Rerun.codeNotShownRunning, workers: 1)
        )
        XCTAssertEqual(records.last?.log, records.last.map { MutationTestLog.rerunFileName(for: $0.key) })
        // The progress counts each mutant once.
        XCTAssertEqual(sent().filter { $0.name == .newMutationTestOutcomeAvailable }.count, 2)
        XCTAssertEqual(sent().filter { $0.name == .unprovenRunRerun }.count, 1)
    }

    func test_aKillThatRunsItsCodeWhenTestedAgain_isAKill_withNoWarning() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantActivations = [false, true, true]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [true, true])
        XCTAssertNil(outcome.unprovenKillWarning)
    }

    func test_aFirstRunThatSurvivesWhenTestedAgain_withItsCodeRunning_isASurvivor() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .runtimeError, .passed, .passed]
        ioDelegate.mutantActivations = [nil, true, true]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [true, true])
    }

    // Its tests fail whatever the mutant, so the kill stands, as the score has no other verdict for it, and the run
    // says so, with the log to show it.
    func test_aKillThatStillDoesntRunItsCode_standsWithAWarning() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantActivations = [false, true, nil]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(outcome.mutations.map(\.activated), [false, true])
        XCTAssertEqual(try XCTUnwrap(outcome.unprovenKillWarning).hasPrefix("1 kill's code never ran"), true)
        let log = try resultsFiles.records(MutantResult.self).last?.log
        XCTAssertNotNil(log, "the log is what the warning has to show")
    }

    // Under `swift test`'s stop at the first failed test, a real kill's marker is there before its failure.
    func test_aKillThatRanItsCode_isntTestedAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .runtimeError]
        ioDelegate.mutantActivations = [true, true]

        _ = try await run()

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 2)
    }

    // A mutant's verdict from `--mutant` is already out, and its log shows what happened.
    func test_oneMutantsRun_isntTestedAgain() async throws {
        state.selectedMutant = MutantKey(
            path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 1, column: 5, occurrence: 0
        )
        state.mutationMapping = try [makeMapping(lines: [1])]
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        ioDelegate.mutantActivations = [false]

        _ = try await run()

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 1)
    }

    // MARK: - Timeouts

    // One worker has tested no timeout again, so this is its one chance to be.
    func test_oneWorkersTimeoutThatDidntRunItsCode_isTestedAgain_butOneThatDid_isnt() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .timeout, .passed]
        ioDelegate.mutantActivations = [false, true, false]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.noCoverage, .timeout])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 3)
    }

    // More than one worker tests every timeout again, once, and whichever run showed the block ran stands.
    func test_workersTestATimeoutAgainOnce_andAKeepsThatItsCodeRan() async throws {
        state.muterConfiguration = swiftTest(workers: 2)
        // The baseline, the clone's build, the two mutants, then the timeouts' reruns.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .timeout, .timeout, .passed, .passed]
        ioDelegate.mutantActivations = [true, false, nil, nil]

        let outcome = try await run()

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 4, "each timeout again, and only once")
        XCTAssertEqual(outcome.mutations.filter { $0.activated == true }.map(\.testSuiteOutcome), [.passed])
        // The session shows runs can say, so a rerun that says nothing didn't reach mutated code.
        XCTAssertEqual(outcome.mutations.filter { $0.activated == false }.map(\.testSuiteOutcome), [.noCoverage])
    }

    // It failed without showing its code ran, as any other such kill has, so it is tested again, as one would be on
    // one worker, and what that shows stands.
    func test_workersTimeoutThatTurnsIntoAKillWithoutItsCode_isTestedAgainToo() async throws {
        state.muterConfiguration = swiftTest(workers: 2)
        state.mutationMapping = try [makeMapping(lines: [1, 2])]
        // The baseline, the clone's build, the two mutants, the timeout's rerun, then the kill's.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .timeout, .passed, .runtimeError, .passed]
        ioDelegate.mutantActivations = [false, true, nil, false]

        let outcome = try await run()

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.compactMap(\.rerun?.because), ["timeout", "codeNotShownRunning"])
        XCTAssertEqual(Set(outcome.mutations.map(\.testSuiteOutcome)), [.noCoverage, .passed])
    }

    // MARK: - The rerun on several workers

    // The first of the pool, one at a time, after the first runs.
    func test_workersTestAKillAgainOnTheFirstWorker() async throws {
        state.muterConfiguration = swiftTest(workers: 2)
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed, .passed]
        ioDelegate.mutantActivations = [false, true, false]

        let outcome = try await run()

        XCTAssertEqual(ioDelegate.workingDirectories.last, state.mutatedProjectDirectoryURL)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 3)
        XCTAssertEqual(Set(outcome.mutations.map(\.testSuiteOutcome)), [.noCoverage, .passed])
    }

    // A rerun that times out is what it comes to, and its line says it was run again, so a resume keeps it.
    func test_aKillThatTimesOutWhenTestedAgain_isATimeout_thatAResumeKeeps() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .timeout]
        ioDelegate.mutantActivations = [false, true, true]
        ioDelegate.mutantRunEndings = [.exited, .exited, .timedOut]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.timeout, .passed])
        XCTAssertEqual(try planFromTheLines().toRun, [])
    }

    // MARK: - Stopping and resuming

    // The first runs' lines stay, and no rerun's is written, so a resume tests those kills again.
    func test_aStopBeforeTheRerun_leavesTheKillForAResumeToTestAgain() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .runtimeError, .passed, .passed]
        ioDelegate.mutantActivations = [false, nil, true, true]
        let mutationTesting = CancellableTask<[MutationTestState.Change]>()
        let observer = runEvents.observe(.unprovenRunsRerunStarted) { _ in mutationTesting.cancel() }
        addTeardownBlock { observer.cancel() }

        let result = await mutationTesting.run { [sut, state] in try await sut.run(with: state) }

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.rerun), [nil, nil])
        // The one whose run reached mutated code, and the one that showed nothing, in a session whose runs can say.
        XCTAssertEqual(try planFromTheLines().retestedBecause, [.codeNotShownRunning: 2])
    }

    // MARK: - With property tests

    // After the rerun, so a kill it settles can be one, and one it overturns isn't.
    func test_propertyRerunsFollow_andLeaveOutAKillThatStillDoesntRunItsCode() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift",
            arguments: ["test"],
            testSuiteTimeOut: 42,
            mutationTestWorkers: 1,
            propertyTests: ["*Properties*"],
            propertyTestFilter: ["Properties"]
        )
        let sum = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
        // Two kills without their code, then the first runs it, failing, and the second doesn't.
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [sum, sum, sum, sum, "✔ passed"]
        ioDelegate.mutantActivations = [false, false, true, nil, true]
        ioDelegate.controlRuns = [(.passed, "✔ Test run with 3 tests in 1 suite passed after 0.4 seconds.")]

        _ = try await run()

        XCTAssertEqual(
            try resultsFiles.kinds(),
            ["header", "mutant", "mutant", "mutant", "mutant", "propertyRerun", "end"]
        )
        XCTAssertEqual(try resultsFiles.records(PropertyRerunResult.self).map(\.line), [1])
    }

    // MARK: - Runs that show nothing

    // A test host that can't write its marker has real kills. They keep their verdicts, and aren't tested again.
    func test_aRunThatNeverShowsAnything_keepsItsVerdicts_andSaysSo() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantActivations = [nil, nil]
        let sent = recordEvents(named: [.activationNotShown, .unprovenRunsRerunStarted])

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).count, 2)
        XCTAssertEqual(sent().map(\.name), [.activationNotShown])
        XCTAssertEqual(sent().first?.object as? Int, 2)
    }

    // A wrapper that drops the variable: no mutant is switched on, though coverage says the tests reach them.
    func test_fiveSwiftTestRunsWithCoverageThatShowNothing_stopTheRun() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)

        do {
            _ = try await sut.run(with: state)
            XCTFail("Expected the run to stop")
        } catch let MuterError.mutationTestingAborted(reason) {
            XCTAssertEqual(reason, .noMutantCodeShownRunning(runs: 5))
        }
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.detail), ["noMutantCodeShownRunning"])
    }

    func test_oneRunThatShowsSomething_keepsTheRunGoing() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)
        ioDelegate.mutantActivations = [false, nil, nil, nil, nil, nil]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
    }

    // Without coverage the tests may reach no mutant at all.
    func test_withoutCoverage_theyOnlySaySo() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .null
        let sent = recordEvents(named: [.activationNotShown])

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
        XCTAssertEqual(sent().first?.object as? Int, 6)
    }

    // A test host may be unable to write.
    func test_underXcodebuild_theyOnlySaySo() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/xcodebuild", arguments: ["test"], testSuiteTimeOut: 42, mutationTestWorkers: 1
        )

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
    }

    // A test plan's code may be an older SwiftMutator's, which writes no marker.
    func test_underATestPlan_theyOnlySaySo() async throws {
        givenFiveMutantsThatShowNothing()
        state.projectCoverage = .make(percent: 78)
        state.runOptions = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 6)
    }

    // Build errors tested nothing, so they say nothing of whether runs can show it.
    func test_buildErrors_dontCountTowardTheStop() async throws {
        state.mutationMapping = try [makeMapping(lines: Array(1...3))]
        state.projectCoverage = .make(percent: 78)
        ioDelegate.testSuiteOutcomes = [.passed, .buildError, .buildError, .buildError]
        ioDelegate.mutantActivations = [nil, nil, nil]

        let outcome = try await run()

        XCTAssertEqual(outcome.mutations.count, 3)
    }

    // MARK: - Helpers

    private func swiftTest(workers: Int) -> MuterConfiguration {
        MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], testSuiteTimeOut: 42, mutationTestWorkers: workers
        )
    }

    private func givenFiveMutantsThatShowNothing() {
        // Six, so a run that didn't stop tests one more than the stop allows.
        state.mutationMapping = (try? [makeMapping(lines: Array(1...6))]) ?? []
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .passed, count: 6)
        ioDelegate.mutantActivations = Array(repeating: nil, count: 6)
    }

    /// The plan of a `--resume` of the results file as it stands, with every file as it was recorded.
    private func planFromTheLines() throws -> ResumePlan {
        let recorded = try RecordedResults.read(Data(resultsFiles.lines.joined(separator: "\n").utf8), path: "/logs/r")
        let keys = recorded.latest.keys.sorted { $0.description < $1.description }
        return ResumePlan.make(
            keys: keys,
            snapshots: keys.map { recorded.latest[$0]?.snapshot ?? .null },
            recorded: recorded.latest,
            fileHashes: [Self.path: Self.hash],
            workers: ResumePlan.workers(of: recorded.headers),
            limits: ResumePlan.limits(of: recorded.headers),
            sessionsShowingNoCode: ResumePlan.showingNoCode(recorded.sessions)
        )
    }

    private func run() async throws -> MutationTestOutcome {
        let changes = try await sut.run(with: state)
        guard case let .mutationTestOutcomeGenerated(outcome)? = changes.first else {
            throw MuterError.literal(reason: "Expected an outcome, got \(changes)")
        }
        return outcome
    }

    private func recordEvents(named names: [RunEvent.Name]) -> () -> [RunEvent] {
        var sent: [RunEvent] = []
        let observer = runEvents.observe { event in
            if names.contains(event.name) { sent.append(event) }
        }
        addTeardownBlock { observer.cancel() }
        return { sent }
    }

    private func makeMapping(lines: [Int]) throws -> SchemataMutationMapping {
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
