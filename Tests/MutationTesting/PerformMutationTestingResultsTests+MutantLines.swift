@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingResultsTests {
    func test_eachMutantsLineIsWrittenBeforeItsEvents() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        var mutantLinesAtEachOutcome: [Int] = []
        var mutantLinesAtEachLog: [Int] = []
        whenSent(.newMutationTestOutcomeAvailable) { _ in
            mutantLinesAtEachOutcome.append((try? self.resultsFiles.records(MutantResult.self).count) ?? -1)
        }
        whenSent(.newTestLogAvailable) { event in
            guard (event.object as? MutationTestLog)?.mutationPoint != nil else { return }
            mutantLinesAtEachLog.append((try? self.resultsFiles.records(MutantResult.self).count) ?? -1)
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(mutantLinesAtEachOutcome, [1, 2])
        XCTAssertEqual(mutantLinesAtEachLog, [1, 2])
    }

    func test_aMutantLineCarriesKeyPathOutcomeEndingDurationAndWorker() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .timeout, .passed]
        ioDelegate.mutantRunEndings = [.timedOut, .exited]
        let ticks = Locked<UInt64>(0)
        current.instant = {
            ticks.change { count in
                count += 1
                return DispatchTime(uptimeNanoseconds: count * 1_500_000_000)
            }
        }
        let schemata = state.mutationMapping.flatMap(\.mutationSchemata)

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.key), [
            MutantKey(path: "Sources/Sum.swift", mutationOperatorId: .ror, line: 3, column: 5, occurrence: 0),
            MutantKey(path: "Sources/Product.swift", mutationOperatorId: .ror, line: 7, column: 5, occurrence: 0),
        ])
        XCTAssertEqual(mutants.map(\.session), [1, 1])
        XCTAssertEqual(mutants.map(\.outcome), [.timeout, .passed])
        XCTAssertEqual(mutants.map(\.endedBy), [.timedOut, .exited])
        XCTAssertEqual(mutants.map(\.durationSeconds), [1.5, 1.5])
        XCTAssertEqual(mutants.map(\.worker), [0, 0])
        XCTAssertEqual(mutants.map(\.finishedAt), [current.now(), current.now()])
        XCTAssertEqual(mutants.map(\.switchID), schemata.map(\.id))
        XCTAssertEqual(mutants.map(\.utf8Offset), [30, 70])
        XCTAssertEqual(mutants.map(\.snapshot), schemata.map(\.snapshot))
        XCTAssertEqual(mutants.map(\.log), [
            "RelationalOperatorReplacement @ Sum.swift-3-5 670192af8b34c2a4.log",
            "RelationalOperatorReplacement @ Product.swift-7-5 b1e0a12406c79b08.log",
        ])
    }

    // Two same-named files with a mutant at one place, and a mutant discovered twice at another: each keeps a log of
    // its own, under the name its line gives.
    func test_eachMutantKeepsALogOfItsOwn_namedByItsLine() async throws {
        let app = try makeSchemataMapping(file: "Sources/App/Check.swift", line: 3)
        state.mutationMapping = try [app, makeSchemataMapping(file: "Sources/Tool/Check.swift", line: 3), app]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        let sent = recordEvents(named: [.newTestLogAvailable])

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.log), [
            "RelationalOperatorReplacement @ Check.swift-3-5 24bcdd71ccc09bff.log",
            "RelationalOperatorReplacement @ Check.swift-3-5 d7fac045dd38392a.log",
            "RelationalOperatorReplacement @ Check.swift-3-5 24bcdd71ccc09bff (#2).log",
        ])
        let kept = sent()
            .compactMap { $0.object as? MutationTestLog }
            .filter { $0.mutationPoint != nil }
            .map(\.keptFileName)
        XCTAssertEqual(kept, mutants.map(\.log))
    }

    // By default, a kill by a failed test its line names keeps no log: `killedBy` and `firstFailedTestLine` stand in
    // for it. Its line has no `log`, nothing is written for it, and its output is discarded, so the header is in format
    // 4.
    func test_byDefault_aKillByATestItsLineNames_keepsNoLog() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog, "survivor's log"]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.outcome), [.failed, .passed])
        XCTAssertNil(mutants[0].log)
        XCTAssertEqual(mutants[0].killedBy, [.init(name: "sum()", location: "SumTests.swift:12:5")])
        let survivorsLog = try XCTUnwrap(mutants[1].log)
        XCTAssertEqual(fileManager.createdFiles["/logs/" + survivorsLog], Data("survivor's log".utf8))
        let killsLog = "/logs/" + MutationTestLog.keptFileName(for: mutants[0].key)
        XCTAssertFalse(fileManager.paths.contains(killsLog), "\(fileManager.paths)")
        let discarded = ioDelegate.keptOutputs.filter { $0.path == nil }.map(\.output)
        XCTAssertEqual(discarded.count, 1)
        XCTAssertEqual(discarded.first?.hasPrefix("/logs/running/0_Sum.swift"), true, "\(discarded)")
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.formatVersion, ResultsCoding.omittedLogsFormatVersion)
    }

    // Survivors, crashes, timeouts and build errors keep their logs, even when the log names failed tests, as does a
    // kill whose line names no test, since nothing in its line stands in for its log.
    func test_byDefault_everyRunButAKillByANamedTest_keepsItsLog() async throws {
        state.mutationMapping = try (1...6).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        ioDelegate.testSuiteOutcomes = [.passed, .passed, .runtimeError, .timeout, .buildError, .buildError, .failed]
        ioDelegate.mutantRunEndings = [.exited, .exited, .timedOut, .exited, .couldNotRun, .exited]
        let summaryOnly = "✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue."
        ioDelegate.mutantTestLogs = ["passed", killingLog, killingLog, "error: build", "couldn't start", summaryOnly]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.outcome), [.passed, .runtimeError, .timeout, .buildError, .buildError, .failed])
        XCTAssertEqual(mutants.map(\.log), mutants.map { MutationTestLog.keptFileName(for: $0.key) })
        XCTAssertEqual(mutants[5].killedBy, [])
        for mutant in mutants {
            XCTAssertNotNil(fileManager.createdFiles["/logs/" + (mutant.log ?? "")], "\(mutant.key)")
        }
        XCTAssertEqual(ioDelegate.keptOutputs.filter { $0.path == nil }.map(\.output), [])
    }

    // `keepAllLogs: true` keeps the kill's log too, so every line names one and the header keeps to format 1.
    func test_keepingAllLogs_aKillByATestItsLineNames_keepsItsLog() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], keepAllLogs: true
        )
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog, "survivor's log"]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        let killsLog = try XCTUnwrap(mutants[0].log)
        XCTAssertEqual(killsLog, MutationTestLog.keptFileName(for: mutants[0].key))
        XCTAssertEqual(fileManager.createdFiles["/logs/" + killsLog], Data(killingLog.utf8))
        XCTAssertEqual(ioDelegate.keptOutputs.filter { $0.path == nil }.map(\.output), [])
        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertEqual(header.formatVersion, ResultsCoding.formatVersion)
    }

    // The hash of the file as the copy held it before discovery rewrote it, so a later run can tell whether the
    // mutant's file is still the one it was tested in.
    func test_aMutantLineCarriesItsFilesHash() async throws {
        let tree = makeProjectTree(["Sources/Sum.swift": "5a1c", "Sources/Product.swift": "77e0", "README.md": "0b9d"])
        state.projectTree = tree
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.path), ["Sources/Sum.swift", "Sources/Product.swift"])
        XCTAssertEqual(mutants.first?.fileSHA256, tree.files["Sources/Sum.swift"])
        XCTAssertEqual(mutants.map(\.fileSHA256), ["5a1c", "77e0"])
    }

    func test_parallelLines_nameTheirWorker_andMatchTheJobsByKey() async throws {
        state.muterConfiguration = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], mutationTestWorkers: 2
        )
        state.mutationMapping = try (1...4).map { try makeSchemataMapping(file: "Sources/File\($0).swift", line: $0) }
        // The baseline, the worker clone's build, then the four mutants.
        ioDelegate.testSuiteOutcomes = [.passed, .passed] + Array(repeating: .failed, count: 4)
        // The first run to start waits until the last one has started, so the other worker runs the other three
        // mutants meanwhile and the runs finish out of job order. A line given the key of the job that finished in
        // its place would then disagree with itself. The wait is bounded, so the test can't hang.
        let lastRunStarted = DispatchSemaphore(value: 0)
        ioDelegate.whileRunningMutant = { number in
            if number == 0 { _ = lastRunStarted.wait(timeout: .now() + 5) }
            if number == 3 { lastRunStarted.signal() }
        }

        _ = try await sut.run(with: state)

        XCTAssertEqual(try resultsFiles.records(ResultsHeader.self).map(\.workers), [2])
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(
            Set(mutants.map(\.key)),
            Set((1...4).map {
                MutantKey(path: "Sources/File\($0).swift", mutationOperatorId: .ror, line: $0, column: 5, occurrence: 0)
            })
        )
        // The lines' order is the order the runs finished in, told by what each takes from its schema, not its key.
        XCTAssertNotEqual(mutants.map(\.utf8Offset), [10, 20, 30, 40], "the runs didn't finish out of job order")
        // Each line's key is its own mutant's: everything the line takes from the mutant's schema agrees with it.
        let schemata = state.mutationMapping.flatMap(\.mutationSchemata)
        for mutant in mutants {
            let schema = try XCTUnwrap(schemata.first { $0.filePath == "/project_mutated/\(mutant.path)" })
            XCTAssertEqual(mutant.utf8Offset, schema.position.utf8Offset, "\(mutant.key)")
            XCTAssertEqual(mutant.switchID, schema.id, "\(mutant.key)")
            XCTAssertEqual(mutant.log, MutationTestLog.keptFileName(for: mutant.key), "\(mutant.key)")
        }
        XCTAssertEqual(Set(mutants.map(\.worker)), [0, 1])
        // Each line names the worker whose folder its mutant ran in.
        let ranIn = { (directory: URL) in self.ioDelegate.workingDirectories.filter { $0 == directory }.count }
        XCTAssertEqual(mutants.filter { $0.worker == 0 }.count, ranIn(state.mutatedProjectDirectoryURL))
        XCTAssertEqual(mutants.filter { $0.worker == 1 }.count, ranIn(workerClone))
    }

    // The outcome the run reports names them as its results line does.
    func test_aKilledMutantNamesItsFailedTests() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]
        ioDelegate.mutantTestLogs = [killingLog, "✔ Test run with 1 test in 0 suites passed after 0.001 seconds."]

        let changes = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.count, 2)
        XCTAssertEqual(mutants.first?.killedBy, [.init(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertEqual(mutants.first?.failedTestCount, 1)
        XCTAssertEqual(
            mutants.first?.firstFailedTestLine,
            "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
        )
        XCTAssertNil(mutants.last?.killedBy)
        XCTAssertNil(mutants.last?.failedTestCount)
        let reported = try XCTUnwrap(outcome(of: changes))
        XCTAssertEqual(reported.mutations.map(\.testSuiteOutcome), [.failed, .passed])
        let line = try XCTUnwrap(mutants.first)
        XCTAssertEqual(reported.mutations.first?.killingTests, MutationTestOutcome.KillingTests(line))
        XCTAssertEqual(reported.mutations.first?.killingTests, sumKilled)
        XCTAssertNil(reported.mutations.last?.killingTests)
    }

    // Such lines are the tests' own text, printed whatever the mutant: the tests they show failing are left out of
    // each mutant's list, and the others still named.
    func test_killedBy_leavesOutTheTestsThePassingBaselinesLinesShowedFailing() async throws {
        let lookalike = "✘ Test parsesAFailure() recorded an issue at ParserTests.swift:3:5: Expectation failed: 1 == 2"
        ioDelegate.baselineTestLog = """
        ◇ Test run started.
        \(lookalike)
        ✔ Test run with 1 test in 0 suites passed after 0.001 seconds.
        """
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantTestLogs = [lookalike + "\n" + killingLog, "◇ Test run started.\n" + lookalike]

        let changes = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertFalse(header.failedTestLinesAreReliable)
        XCTAssertEqual(header.failedTestLookalikes, [.init(name: "parsesAFailure()", file: "ParserTests.swift")])
        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.outcome), [.failed, .failed])
        XCTAssertEqual(mutants.map(\.killedBy), [[.init(name: "sum()", location: "SumTests.swift:12:5")], []])
        XCTAssertEqual(mutants.map(\.failedTestCount), [1, 0])
        XCTAssertEqual(
            mutants.map(\.firstFailedTestLine),
            ["✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4", nil]
        )
        XCTAssertEqual(try XCTUnwrap(outcome(of: changes)).mutations.map(\.killingTests), [
            .init(tests: [.init(name: "sum()", location: "SumTests.swift:12:5")], count: 1, isComplete: true),
            .init(tests: [], count: 0, isComplete: true),
        ])
    }

    func test_aHeaderRecordsNoFailedTestLookalikes_whenTheBaselinePrintedNone() async throws {
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]
        ioDelegate.mutantTestLogs = [killingLog, killingLog]

        _ = try await sut.run(with: state)

        let header = try XCTUnwrap(resultsFiles.records(ResultsHeader.self).first)
        XCTAssertTrue(header.failedTestLinesAreReliable)
        XCTAssertNil(header.failedTestLookalikes)
    }

    func test_repeatedMutants_getDistinctKeys() async throws {
        state.mutationMapping = try [
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
            makeSchemataMapping(file: "Sources/Sum.swift", line: 3),
        ]
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed]

        _ = try await sut.run(with: state)

        let mutants = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(mutants.map(\.path), ["Sources/Sum.swift", "Sources/Sum.swift"])
        XCTAssertEqual(mutants.map(\.occurrence), [0, 1])
        XCTAssertEqual(mutants.map(\.outcome), [.failed, .passed])
    }
}
