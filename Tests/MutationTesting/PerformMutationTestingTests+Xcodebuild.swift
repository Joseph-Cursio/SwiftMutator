@testable import muterCore
import SwiftSyntax
import TestingExtensions
import XCTest

extension PerformMutationTestingTests {
    // Rather than in a new folder of ~/Library/Developer/Xcode/DerivedData for each run. The folder goes with the run.
    func test_xcodebuildMutantsRuns_keepTheirDerivedDataBesideTheCopy_untilTheRunEnds() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.apply([.testDiagnosticsOptionChecked(canBeTurnedOff: true)])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        let worker = MuterConfiguration.XcodeWorker(
            testRunFile: "muter.xctestrun",
            derivedData: "/project_mutated.DerivedData.noindex",
            testDiagnosticsOff: true
        )
        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), [worker, worker])
        XCTAssertEqual(
            fileManager.paths.filter { $0.contains(".DerivedData") },
            ["/project_mutated.DerivedData.noindex"]
        )
    }

    // Only an xcodebuild that lists the option in its `-help` gets it (see BuildForTesting).
    func test_xcodebuildMutantsRuns_keepTestDiagnostics_unlessTheTestCommandTakesTheOption() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map { $0.xcodeWorker?.testDiagnosticsOff }, [false, false])
    }

    // Before the baseline: a booted simulator an earlier run left holds memory the baseline could use.
    func test_anXcodebuildRun_sweepsLeftoverWorkerSimulators_beforeTheBaseline() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.failed]

        try await assertThrowsMuterError(await sut.run(with: state)) { _ in }

        XCTAssertEqual(workerSimulators.calls, ["sweep /project_mutated"])
    }

    func test_aSwiftPMRun_leavesSimulatorsAlone() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(workerSimulators.calls, [])
    }

    func test_swiftPMMutantsRuns_haveNoXcodeWorker() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"])
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed]

        _ = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.configurations.map(\.xcodeWorker), [nil, nil])
        XCTAssertFalse(fileManager.paths.contains { $0.contains(".DerivedData") })
    }

    // A real run that found the simulator still busy with the run before. It tested nothing, so the mutant runs again
    // on the same simulator, still switched on, and only that run is recorded and counted. The first run's log is kept.
    func test_whenTheSimulatorFailsToLaunchARun_itRunsOnceMore_andOnlyThatRunIsRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [launchFailed, "the second run's log", "testLog"]
        let sent = recordEvents(named: [.runRepeatedAfterLaunchFailure, .newTestLogAvailable])

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls, [
            "benchmarkTests(using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestsWithoutBuilding(using:timeLimit:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
            "switchOn(schemata:for:at:named:)",
            "runTestSuite(withSchemata:using:savingResultsIntoFileNamed:)",
        ])
        XCTAssertEqual(outcomes(in: result), [.passed, .failed])
        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.outcome), [.passed, .failed])
        XCTAssertEqual(sent().map(\.name), [
            .newTestLogAvailable, // the baseline's
            .runRepeatedAfterLaunchFailure,
            .newTestLogAvailable,
            .newTestLogAvailable,
        ])
        let repeated = try XCTUnwrap(sent().compactMap { $0.object as? RepeatedRun }.first)
        XCTAssertEqual(repeated.worker, 0)
        XCTAssertEqual(repeated.mutant.testSuiteOutcome, .passed)
        XCTAssertEqual(repeated.line, "Simulator device failed to launch com.example.MacCloud-client-iOS.")
        XCTAssertEqual(repeated.log.testLog, launchFailed)
        let firstLog = try XCTUnwrap(records[0].log)
        XCTAssertEqual(repeated.log.keptFileName, MutationTestLog.launchFailedFileName(for: firstLog))
        let logs = sent().compactMap { $0.object as? MutationTestLog }.map(\.testLog)
        XCTAssertEqual(logs.dropFirst(), ["the second run's log", "testLog"])
        // The first run's from its text, as the second wrote over its file; the second's from that file.
        let launchFailedLog = "/logs/" + MutationTestLog.launchFailedFileName(for: firstLog)
        XCTAssertEqual(fileManager.createdFiles[launchFailedLog], Data(launchFailed.utf8))
        XCTAssertEqual(fileManager.createdFiles["/logs/" + firstLog], Data("the second run's log".utf8))
        XCTAssertFalse(ioDelegate.keptOutputs.contains { $0.path == launchFailedLog })
    }

    // A kill by a test its line names keeps no log, but the run the simulator failed to launch before it keeps its
    // own, which says why it ran again.
    func test_aKillAfterALaunchFailure_keepsTheLaunchFailedLog_butNoneOfItsOwn() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        let killing = "✘ Test sum() recorded an issue at SumTests.swift:12:5: Expectation failed: 3 == 4"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .passed]
        ioDelegate.mutantTestLogs = [launchFailed, killing, "testLog"]

        _ = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(records.map(\.outcome), [.failed, .passed])
        XCTAssertEqual(records[0].killedBy, [.init(name: "sum()", location: "SumTests.swift:12:5")])
        XCTAssertNil(records[0].log)
        let wouldBe = MutationTestLog.keptFileName(for: fileKey(0))
        let launchFailedLog = "/logs/" + MutationTestLog.launchFailedFileName(for: wouldBe)
        XCTAssertEqual(fileManager.createdFiles[launchFailedLog], Data(launchFailed.utf8))
        XCTAssertNil(fileManager.createdFiles["/logs/" + wouldBe])
    }

    // A real baseline that found Xcode's clone of the simulator busy. It tested nothing, so it runs once more, and
    // mutation testing goes on from that run. The first run's log is kept beside the baseline's.
    func test_whenTheSimulatorFailsToLaunchTheBaseline_itRunsOnceMore_andTestingGoesOn() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        ioDelegate.testSuiteOutcomes = [.failed, .passed, .failed, .failed]
        ioDelegate.baselineTestLogs = [launchFailed, "the second baseline's log"]
        let sent = recordEvents(named: [.baselineRepeatedAfterLaunchFailure, .newTestLogAvailable])

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count, 2)
        XCTAssertEqual(outcomes(in: result), [.failed, .failed])
        XCTAssertEqual(sent().map(\.name), [
            .baselineRepeatedAfterLaunchFailure,
            .newTestLogAvailable, // the second baseline's
            .newTestLogAvailable,
            .newTestLogAvailable,
        ])
        let (line, log) = try XCTUnwrap(sent().first?.object as? (String, MutationTestLog))
        XCTAssertEqual(line, "Simulator device failed to launch com.example.MacCloud-client-iOS.")
        XCTAssertEqual(log.testLog, launchFailed)
        XCTAssertNil(log.mutationPoint)
        XCTAssertEqual(log.keptFileName, "baseline run (launch failed).log")
        let baselineLog = try XCTUnwrap(sent()[1].object as? MutationTestLog)
        XCTAssertEqual(baselineLog.testLog, "the second baseline's log")
        XCTAssertEqual(fileManager.createdFiles["/logs/baseline run (launch failed).log"], Data(launchFailed.utf8))
        XCTAssertEqual(fileManager.createdFiles["/logs/baseline run.log"], Data("the second baseline's log".utf8))
        XCTAssertEqual(ioDelegate.keptOutputs.filter { $0.output == "/logs/running/baseline run" }.count, 1)
    }

    // One more baseline at most, which fails mutation testing as any failed baseline does. A SwiftPM baseline has no
    // simulator, so its failure is never run again.
    func test_aBaselineTheSimulatorFailsToLaunchTwice_andASwiftPMBaseline_failAsAnyFailedBaselineDoes() async throws {
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        let sent = recordEvents(named: [.baselineRepeatedAfterLaunchFailure])
        for (executable, baselines) in [("/usr/bin/xcodebuild", 2), ("/usr/bin/swift", 1)] {
            state.muterConfiguration = MuterConfiguration(executable: executable, arguments: ["test"])
            let baselinesBefore = ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count
            ioDelegate.testSuiteOutcomes = [.failed, .failed]
            ioDelegate.baselineTestLogs = [launchFailed, launchFailed]

            try await assertThrowsMuterError(await sut.run(with: state)) { error in
                guard case .mutationTestingAborted(reason: .baselineTestFailed) = error else {
                    return XCTFail("Expected mutationTestingAborted, got \(error)")
                }
            }

            let baselinesRun = ioDelegate.methodCalls.filter { $0.hasPrefix("benchmarkTests") }.count - baselinesBefore
            XCTAssertEqual(baselinesRun, baselines, executable)
        }
        XCTAssertEqual(sent().count, 1)
    }

    // The second run's line is on disk before the console says the mutant ran again or keeps the first run's log, so a
    // stop at once after that never leaves a mutant said to have run again with no line.
    func test_aRunTheSimulatorFailedToLaunch_isSentOnlyOnceTheSecondRunsResultIsWritten() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .passed, .failed]
        ioDelegate.mutantTestLogs = [loadFixture("SimulatorTrouble/launch_preflightBusy.log")]
        var recordedWhenSent: [[TestSuiteOutcome]] = []
        let observer = runEvents.observe(.runRepeatedAfterLaunchFailure) { [resultsFiles] _ in
            recordedWhenSent.append((try? resultsFiles.records(MutantResult.self).map(\.outcome)) ?? [])
        }
        addTeardownBlock { observer.cancel() }

        _ = try await sut.run(with: state)

        XCTAssertEqual(recordedWhenSent, [[.passed]])
    }

    // One more run at most: a mutant that crashes its app at launch would otherwise run for ever. That run counts,
    // whatever it comes to.
    func test_whenTheSimulatorFailsToLaunchARunTwice_theSecondIsRecorded() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        let launchFailed = loadFixture("SimulatorTrouble/launch_beforeEstablishingConnection.log")
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .failed, .failed]
        ioDelegate.mutantTestLogs = [launchFailed, launchFailed]
        let sent = recordEvents(named: [.runRepeatedAfterLaunchFailure])

        let result = try await sut.run(with: state)

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 3)
        XCTAssertEqual(outcomes(in: result), [.failed, .failed])
        XCTAssertEqual(sent().count, 1)
    }

    // A run that passed tested its mutant, whatever its log says; another build system's run has no simulator.
    func test_aPassedRun_andASwiftPMRun_neverRunAgain() async throws {
        let launchFailed = loadFixture("SimulatorTrouble/launch_preflightBusy.log")
        let sent = recordEvents(named: [.runRepeatedAfterLaunchFailure])
        let runs: [(executable: String, outcomes: [TestSuiteOutcome])] = [
            ("/usr/bin/xcodebuild", [.passed, .passed]),
            ("/usr/bin/swift", [.failed, .failed]),
        ]
        for (executable, recorded) in runs {
            state.muterConfiguration = MuterConfiguration(executable: executable, arguments: ["test"])
            ioDelegate.testSuiteOutcomes = [.passed] + recorded
            ioDelegate.mutantTestLogs = [launchFailed, launchFailed]

            let result = try await sut.run(with: state)

            XCTAssertEqual(outcomes(in: result), recorded, executable)
        }
        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 4)
        XCTAssertEqual(sent().count, 0)
    }

    // A real run on a simulator deleted before it. Every run on it would fail the same way without a test, and count as
    // a kill, so mutation testing stops without recording it, keeps its log, and keeps what it recorded before.
    func test_whenARunsSimulatorIsGone_mutationTestingStops_withoutRecordingTheRun() async throws {
        state.muterConfiguration = MuterConfiguration(executable: "/usr/bin/xcodebuild", arguments: ["test"])
        state.loggingDirectory = "/logs"
        let gone = loadFixture("SimulatorTrouble/deviceGone_unableToFind.log")
        ioDelegate.testSuiteOutcomes = [.passed, .failed, .buildError]
        ioDelegate.mutantTestLogs = ["testLog", gone]
        let sent = recordEvents(named: [.mutationTestingEndedEarly])

        do {
            _ = try await sut.run(with: state)
            XCTFail("expected an abort")
        } catch let MuterError.mutationTestingAborted(reason: .simulatorUnavailable(worker, line, log)) {
            XCTAssertEqual(worker, 0)
            XCTAssertEqual(
                line, "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
            )
            let kept = try XCTUnwrap(log)
            XCTAssertTrue(kept.hasPrefix("/logs/") && kept.hasSuffix(" (simulator gone).log"), kept)
            XCTAssertEqual(fileManager.createdFiles[kept], Data(gone.utf8))
            // Moved from the file the run wrote.
            let moved = try XCTUnwrap(ioDelegate.keptOutputs.last)
            XCTAssertTrue(moved.output.hasPrefix("/logs/running/1_"), moved.output)
            XCTAssertEqual(moved.path, kept)
        }

        XCTAssertEqual(ioDelegate.methodCalls.filter { $0.hasPrefix("runTestSuite") }.count, 2, "no run again")
        XCTAssertEqual(try resultsFiles.records(MutantResult.self).map(\.outcome), [.failed])
        let earlyEnd = try XCTUnwrap(sent().compactMap { $0.object as? EarlyEnd }.first)
        XCTAssertEqual(earlyEnd.detail, "simulatorUnavailable(worker: 0)")
        XCTAssertEqual(earlyEnd.outcome.mutations.map(\.testSuiteOutcome), [.failed])
    }
}
