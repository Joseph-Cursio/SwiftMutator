@testable import muterCore
import TestingExtensions
import XCTest

extension PerformMutationTestingResumeTests {
    // The first session, on 4 workers, was stopped while it ran its timeouts again: Sum.swift's was run again, and
    // killed, Total.swift's wasn't. Only that one is tested, and the rerun's kill is kept.
    func test_aRunStoppedWhileRunningItsTimeoutsAgain_testsOnlyThoseNotRunAgain() async throws {
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.timeout, workers: 1)
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree, workers: 4),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .failed, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .timeout, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c", rerun: rerun),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", recorded: 5),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed, .passed]
        let sent = recordEvents(named: [.resumePlanned])

        let changes = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.retestedBecause, [.timeoutNotRerun: 1])
        XCTAssertEqual(summary.reused, 3)
        XCTAssertEqual(
            ioDelegate.testLogs.filter { $0.contains("RelationalOperatorReplacement") },
            [running("3_Total.swift_RelationalOperatorReplacement_80_8_5.log")]
        )
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.path), ["Sources/Total.swift"])
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .passed])
    }

    // A resume under a longer limit than the first session's, which `ResumeCheck` let through, tests its timeout
    // again, and keeps its other results: they ended in time under the shorter one.
    func test_aLongerLimit_testsOnlyTheTimeoutsAgain() async throws {
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 4, mutantsToTest: 4, project: tree, timeoutSeconds: 60),
                record(of: "Sources/Product.swift", line: 7, .passed, fileSHA256: "77e0"),
                record(of: "Sources/Quotient.swift", line: 4, .failed, fileSHA256: "3c4f"),
                record(of: "Sources/Sum.swift", line: 3, .failed, fileSHA256: "5a1c"),
                record(of: "Sources/Total.swift", line: 8, .timeout, fileSHA256: "9e21"),
                ResultsEnd.make(recorded: 4),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        state.muterConfiguration = state.muterConfiguration.overriding(workers: nil, timeout: 120)
        ioDelegate.testSuiteOutcomes = [.passed, .failed]
        let sent = recordEvents(named: [.resumePlanned])

        let changes = try await sut.run(with: state)

        let summary = try XCTUnwrap(sent().first?.object as? ResumeSummary)
        XCTAssertEqual(summary.retestedBecause, [.timeoutUnderShorterLimit: 1])
        XCTAssertEqual(summary.reused, 3)
        XCTAssertEqual(ioDelegate.configurations.last?.testSuiteTimeout, 120)
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.path), ["Sources/Total.swift"])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).first?.timeoutSeconds, 120)
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.testSuiteOutcome), [.passed, .failed, .failed, .failed])
    }

    // The first session tested a kill between each two of the build errors it recorded, and those kills are kept, so
    // the build errors are tested again one after another. Failing to build again says nothing new about the build,
    // so they don't count toward stopping after 5 build errors in a row, or no resume of the run could finish.
    func test_buildErrorsTestedAgain_dontCountTowardTheAbort() async throws {
        let lines = Array(1...10)
        state.mutationMapping = try [makeSchemataMapping(file: "Sources/Sum.swift", lines: lines)]
        var records: [any Encodable] = [ResultsHeader.make(mutantsDiscovered: 10, mutantsToTest: 10, project: tree)]
        for line in lines {
            let outcome: TestSuiteOutcome = line.isMultiple(of: 2) ? .failed : .buildError
            records.append(record(of: "Sources/Sum.swift", line: line, outcome, fileSHA256: "5a1c"))
        }
        records.append(ResultsEnd.make(reason: .finished, recorded: 10))
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: records,
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .buildError, count: 5)

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.line), [1, 3, 5, 7, 9])
        XCTAssertEqual(try resultsFiles.records(ResultsEnd.self).map(\.reason), [.finished])
    }

    // Mutants never tested before still stop mutation testing after 5 build errors in a row, as in a first session.
    func test_newBuildErrors_stillStopItAfterFiveInARow() async throws {
        state.mutationMapping = try [makeSchemataMapping(file: "Sources/Sum.swift", lines: Array(1...10))]
        state.resumeState = try ResumeState.make(
            path: resultsPath,
            lines: [
                ResultsHeader.make(mutantsDiscovered: 10, mutantsToTest: 10, project: tree),
                ResultsEnd.make(reason: .interrupted, detail: "SIGINT", recorded: 0),
            ],
            file: XCTUnwrap(state.resumeState).file
        )
        ioDelegate.testSuiteOutcomes = [.passed] + Array(repeating: .buildError, count: 5)

        await assertThrowsMuterError(
            try await sut.run(with: state),
            .mutationTestingAborted(reason: .tooManyBuildErrors)
        )
    }

    // Two mutants are left, so a third and fourth worker would only cost clones.
    func test_workersAreCappedByWhatIsLeft() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 4
        )
        // The baseline, the worker clone's build, then the two mutants left.
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .failed, .passed]

        let changes = try await sut.run(with: state)

        XCTAssertEqual(clonedCounts, [1])
        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        XCTAssertEqual(
            Set(ioDelegate.testLogs.dropFirst(3)),
            [
                running("1_Quotient.swift_RelationalOperatorReplacement_40_4_5.log"),
                running("3_Total.swift_RelationalOperatorReplacement_80_8_5.log"),
            ]
        )
        guard case let .mutationTestOutcomeGenerated(outcome) = changes.first else {
            XCTFail("Expected an outcome, got \(changes)")
            return
        }
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [7, 4, 3, 8])
    }

    // What is reused and why the rest is tested is said first, and the progress bar counts only what is left.
    func test_theProgressTotalIsWhatIsLeft() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        let sent = recordEvents(named: [.resumePlanned, .mutationTestingStarted, .newTestLogAvailable])

        _ = try await sut.run(with: state)

        XCTAssertEqual(
            sent().prefix(3).map(\.name),
            [.resumePlanned, .mutationTestingStarted, .newTestLogAvailable]
        )
        XCTAssertEqual(
            sent().first?.object as? ResumeSummary,
            ResumeSummary(
                path: resultsPath,
                reused: 2,
                toTest: 2,
                retestedBecause: [.buildError: 1, .notRecorded: 1],
                noLongerDiscovered: 1,
                discoveredBefore: 5,
                coverageChange: nil,
                forced: ["toolchain.testCommandVersion"],
                waived: ["README.md"],
                notices: ["mutationTestWorkers was 4 and is 1 now, which no result depends on."]
            )
        )
        let baselineLog = try XCTUnwrap(sent().dropFirst(2).first?.object as? MutationTestLog)
        XCTAssertNil(baselineLog.mutationPoint)
        XCTAssertEqual(baselineLog.remainingMutationPointsCount, 2)
    }
}
