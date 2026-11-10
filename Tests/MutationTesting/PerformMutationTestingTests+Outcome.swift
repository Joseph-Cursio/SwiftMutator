@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingTests {
    // The observer judges the outcome by it, a finished one's or an early end's, which said nothing of it.
    func test_theOutcome_carriesTheConfigurationsFailUnder() async throws {
        state.muterConfiguration = MuterConfiguration(failUnder: 72.5)
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        XCTAssertEqual(finished().compactMap { ($0.object as? MutationTestOutcome)?.failUnder }, [72.5])

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 6)
        ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)
        let ended = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(ended().compactMap { ($0.object as? EarlyEnd)?.outcome.failUnder }, [72.5])
    }

    // The observer compares the survivors only when the outcome carries `--baseline`'s file, and saves a baseline file
    // only with the scope it records: without them, the check is skipped and the run exits 0.
    func test_theOutcome_carriesTheBaselineFile_itsLimit_theScope_andTheFilesToMutate() async throws {
        let file = BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: "0.1.0",
            score: .init(killed: 1, scored: 2),
            scope: BaselineScope(operators: ["RelationalBoundary"], skipCoverage: false, configuration: .init()),
            survivors: []
        )
        let unselected = UnselectedMutant(
            key: MutantKey(path: "Sources/Other.swift", mutationOperatorId: .ror, line: 4, column: 9, occurrence: 0),
            snapshot: .make(before: "<", after: ">"),
            originalProjectPath: "/project/Sources/Other.swift"
        )
        let uncovered = UncoveredMutant(
            key: MutantKey(path: "Sources/New.swift", mutationOperatorId: .ror, line: 2, column: 5, occurrence: 0),
            snapshot: .make(before: "<", after: ">")
        )
        state.runOptions = .make(baseline: "muter.baseline.yml", maxNewSurvivors: 2, writeBaseline: "/out/b.yml")
        state.apply([.baselineFileLoaded(file), .mutantsNotSelected([unselected]), .mutantsNotCovered([uncovered])])
        state.filesToMutate = ["Sources/Sum.swift"]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        let outcome = try XCTUnwrap(finished().compactMap { $0.object as? MutationTestOutcome }.first)
        XCTAssertEqual(outcome.baseline, file)
        XCTAssertEqual(outcome.maxNewSurvivors, 2)
        XCTAssertEqual(outcome.baselineScope, LoadBaselineFile.scope(of: state))
        XCTAssertEqual(outcome.filesToMutate, ["Sources/Sum.swift"])
        XCTAssertEqual(outcome.unselectedMutants, [unselected])
        XCTAssertEqual(outcome.uncoveredMutants, [uncovered])
        XCTAssertFalse(outcome.mutations.contains { $0.key == uncovered.key }, "never a mutation, which a score counts")

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 6)
        ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)
        let ended = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        let early = try XCTUnwrap(ended().compactMap { ($0.object as? EarlyEnd)?.outcome }.first)
        XCTAssertEqual(early.baseline, file)
        XCTAssertEqual(early.maxNewSurvivors, 2)
        XCTAssertEqual(early.baselineScope, LoadBaselineFile.scope(of: state))
        XCTAssertEqual(early.unselectedMutants, [unselected])
        XCTAssertEqual(early.uncoveredMutants, [uncovered])
    }

    // Without `--baseline`, nothing is compared, and the mutants left out aren't carried.
    func test_withoutABaselineFile_theOutcomeCarriesNone() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        let outcome = try XCTUnwrap(finished().compactMap { $0.object as? MutationTestOutcome }.first)
        XCTAssertNil(outcome.baseline)
        XCTAssertNil(outcome.unselectedMutants)
    }

    // The observer saves them, at the end or beside each as partial ones, so their paths are resolved against the
    // project's folder: the run's own is then the mutated copy.
    func test_theOutcome_carriesTheConfigurationsReports_resolved() async throws {
        state.muterConfiguration = MuterConfiguration(reports: [
            ReportRequest(format: .markdown, path: "summary.md"),
            ReportRequest(format: .html, path: "/out/report.html"),
        ])
        let expected = [
            ReportRequest(format: .markdown, path: "/project/summary.md"),
            ReportRequest(format: .html, path: "/out/report.html"),
        ]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        let finished = recordEvents(named: [.mutationTestingFinished])

        _ = try await sut.run(with: state)

        XCTAssertEqual(finished().compactMap { ($0.object as? MutationTestOutcome)?.reports }, [expected])

        state.mutationMapping = try Array(repeating: makeSchemataMapping(), count: 6)
        ioDelegate.testSuiteOutcomes = [.passed, .failed] + Array(repeating: .buildError, count: 5)
        let ended = recordEvents(named: [.mutationTestingEndedEarly])

        await assertThrowsMuterError(try await sut.run(with: state)) { _ in }

        XCTAssertEqual(ended().compactMap { ($0.object as? EarlyEnd)?.outcome.reports }, [expected])
    }

    // The jobs and their keys are there before the baseline runs, so only its passing tells a stop that has something
    // to report from one that hasn't. A stop during the baseline sends no early end; one just after it passed sends
    // one, with nothing tested yet and every mutant discovered.
    func test_anEarlyEnd_isPostedOnlyOnceTheBaselinePassed() async throws {
        ioDelegate.testSuiteOutcomes = [.buildError, .passed]
        ioDelegate.whileRunningBaseline = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        let stoppedDuringTheBaseline = await runInItsOwnTask()

        XCTAssertThrowsError(try stoppedDuringTheBaseline.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(sent().count, 0)

        ioDelegate.whileRunningBaseline = nil
        // The baseline's log is the last thing sent before the first mutant.
        cancelMutationTesting(whenSent: .newTestLogAvailable)

        let stoppedOnceItPassed = await runInItsOwnTask()

        XCTAssertThrowsError(try stoppedOnceItPassed.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        let earlyEnds = sent().compactMap { $0.object as? EarlyEnd }
        XCTAssertEqual(earlyEnds.count, 1)
        let earlyEnd = try XCTUnwrap(earlyEnds.first)
        XCTAssertEqual(earlyEnd.reason, .interrupted)
        XCTAssertEqual(earlyEnd.discovered, 2)
        XCTAssertEqual(earlyEnd.outcome.mutations.count, 0)
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 0)
    }
}
