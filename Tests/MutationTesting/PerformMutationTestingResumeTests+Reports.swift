@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingResumeTests {
    // Gone.swift's kill no longer counts, as this session doesn't discover its mutant: the stopped run couldn't gather
    // coverage, which now leaves Gone.swift out.
    func test_theSummary_countsTheResultsNoLongerDiscovered_andSaysHowCoverageChanged() async throws {
        state.projectCoverage = .make(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.noLongerDiscovered, 1)
        XCTAssertEqual(summary.discoveredBefore, 5)
        XCTAssertEqual(summary.discovered, 4)
        XCTAssertEqual(summary.coverageChange, .gatheredOnlyNow)
    }

    // A sample that no longer takes Gone.swift's mutant after a change: the mutant is still discovered, only not
    // sampled, so its result is counted apart, not warned of as gone.
    func test_theSummary_countsTheResultsOutsideTheSample_apartFromThoseNoLongerDiscovered() async throws {
        let gone = record(of: "Sources/Gone.swift", line: 2, .failed, fileSHA256: "0b9d").key
        state.apply([.sampleLeftOut([gone])])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.outsideTheSample, 1)
        XCTAssertEqual(summary.noLongerDiscovered, 0)
        XCTAssertEqual(try resultsFiles.records(ResultsRetired.self).last?.keys.contains(gone), true)
    }

    // Coverage the stopped run recorded as it is now explains nothing: Gone.swift's mutant is gone for another reason.
    func test_theSummary_withTheSameCoverage_saysNoCoverageChange() async throws {
        let gathered = CoverageSummary(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        recorded[0] = ResultsHeader.make(coverage: gathered, mutantsDiscovered: 5, mutantsToTest: 5, project: tree)
        state.resumeState = try ResumeState.make(
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
        )
        state.projectCoverage = .make(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertNil(summary.coverageChange)
        XCTAssertEqual(summary.noLongerDiscovered, 1)
    }

    // A resume of a test plan's run compares the plan's copy, so what --resume-ignoring let through are its files.
    func test_theSummary_ofATestPlansRun_namesTheCopy() async throws {
        recorded[0] = ResultsHeader.make(mutantsDiscovered: 5, mutantsToTest: 5, project: tree, usingTestPlan: true)
        state.resumeState = try ResumeState.make(
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.testPlanCopy, state.mutatedProjectDirectoryURL.path)
        XCTAssertEqual(summary.waived, ["README.md"])
    }

    // xcodebuild names the files without coverage by their path in the copy, which moved with the project: the stopped
    // run was in another CI agent's checkout. They are the same files.
    func test_theSummary_ofAProjectThatMoved_comparesTheFilesWithoutCoverageInEachCopy() async throws {
        recorded[0] = ResultsHeader.make(
            projectPath: "/agent1/project",
            mutatedProjectPath: "/agent1/project_mutated",
            coverage: CoverageSummary(
                percent: 80,
                filesWithoutCoverage: ["/agent1/project_mutated/Sources/Gone.swift"]
            ),
            mutantsDiscovered: 5,
            mutantsToTest: 5,
            project: tree
        )
        state.resumeState = try ResumeState.make(
            lines: recorded,
            file: XCTUnwrap(state.resumeState).file,
            path: resultsPath
        )
        state.projectCoverage = .make(percent: 80, filesWithoutCoverage: ["/project_mutated/Sources/Gone.swift"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        _ = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertNil(summary.coverageChange)
    }

    // The reporter gets every outcome the report covers, so the Xcode format warns of the kept survivor too. Only the
    // tested mutants send a log, which moves the progress bar and is kept in the session's log folder.
    func test_reusedOutcomesReachTheXcodeReporter_butNoTestLogIsSent() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let outcomes = recordEvents(named: [.newMutationTestOutcomeAvailable])
        let testLogs = recordEvents(named: [.newTestLogAvailable])

        _ = try await sut.run(with: state)

        let sent = outcomes().compactMap { $0.object as? MutationTestOutcome.Mutation }
        XCTAssertEqual(sent.map(\.point.position.line), [7, 3, 4, 8], "the kept ones first, then each as it is tested")
        XCTAssertEqual(sent.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
        XCTAssertEqual(
            testLogs().map { ($0.object as? MutationTestLog)?.mutationPoint?.position.line },
            [nil, 4, 8],
            "the baseline's, then the tested mutants'"
        )
    }

    // The progress lines count each outcome sent after the baseline's log, which starts them, so the kept results
    // come before it. After it, each tested mutant's outcome comes before its log.
    func test_keptOutcomes_comeBeforeTheBaselinesLog() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.newMutationTestOutcomeAvailable, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            sent().map { $0.name == .newTestLogAvailable ? "log" : "outcome" },
            ["outcome", "outcome", "log", "outcome", "log", "outcome", "log"]
        )
    }

    // A stop while Total.swift's mutant runs: the partial report has both kept results and Quotient.swift's, and says
    // how many were kept.
    func test_anInterruptedResumedSession_postsReusedAndNewOutcomes_withItsReusedCount() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var earlyEnds: [EarlyEnd] = []
        whenSent(.mutationTestingEndedEarly) { event in
            if let earlyEnd = event.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnds.count, 1)
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.point.position.line), [7, 4, 3])
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed])
        XCTAssertEqual(earlyEnd.reused, 2)
        XCTAssertEqual(earlyEnd.discovered, 4)
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.recorded), [1])
    }

    // The report covers the whole run, so its duration does too; the end line keeps each session's apart.
    func test_theOutcomesDuration_addsEarlierSessions_whileTheEndLineHasThisOnesOnly() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let calls = Locked(0.0)
        current.now = {
            calls.change { count in
                count += 1
                return ResultsHeader.fixedStart.addingTimeInterval(count * 2.5)
            }
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertGreaterThan(end.testDurationSeconds, 0)
        XCTAssertEqual(outcome.testDuration, 100.5 + end.testDurationSeconds)
    }

    func test_anEarlyEndsDuration_addsEarlierSessions_too() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantRunEndings = [.exited, .cancelled]
        ioDelegate.whileRunningMutant = { number in
            if number == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        var earlyEnds: [EarlyEnd] = []
        whenSent(.mutationTestingEndedEarly) { event in
            if let earlyEnd = event.object as? EarlyEnd { earlyEnds.append(earlyEnd) }
        }

        let result = await sut.runInItsOwnTask(with: state)

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let end = try XCTUnwrap(resultsFiles.records(ResultsEnd.self).first)
        XCTAssertEqual(end.reason, .interrupted)
        XCTAssertEqual(earlyEnds.map(\.outcome.testDuration), [100.5 + end.testDurationSeconds])
    }

    // What was checked before the copy is what is recorded, and the provenance isn't probed again.
    func test_forcedWaivedAndProvenance_comeFromTheResumeState() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let probed = Locked(0)
        current.provenance = { _ in
            probed.change { $0 += 1 }
            return .fixture
        }

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.provenance, checkedProvenance)
        XCTAssertEqual(header.forced, ["toolchain.testCommandVersion"])
        XCTAssertEqual(header.waived, ["README.md"])
        XCTAssertEqual(probed.value, 0)
    }

    // `swift-mutator report` reads the whole file: the stopped run's lines, then this session's. The kept results come
    // from the earlier session's lines, and the rest from this one's.
    func test_aResumedReport_equalsTheReportFromTheFile() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let calls = Locked(0.0)
        current.now = {
            calls.change { count in
                count += 1
                return ResultsHeader.fixedStart.addingTimeInterval(count * 2.5)
            }
        }

        let changes = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        let file = try resultsFileData(recorded) + Data(resultsFiles.lines.map { $0 + "\n" }.joined().utf8)
        let fromTheFile = try RecordedResults.read(file, path: resultsPath)
            .mutationTestOutcome(resultsFile: resultsPath)
        XCTAssertEqual(fromTheFile, outcome)
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
    }
}
