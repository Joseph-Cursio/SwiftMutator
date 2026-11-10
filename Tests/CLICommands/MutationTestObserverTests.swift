@testable import muterCore
// Rainbow's settings are static vars that nothing guards: `@preconcurrency` lets these tests change them unchecked,
// which is safe because XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import XCTest

final class MutationTestObserverTests: MuterTestCase {
    private var options = Run.Options.make()

    private lazy var sut = MutationTestObserver(runOptions: options)

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/"
    }

    // Before it starts, the observer has no folder, so it lists and removes nothing.
    func test_removeLoggingDirectoryIfEmpty_beforeStart_removesNothing() {
        sut.removeLoggingDirectoryIfEmpty()

        XCTAssertTrue(fileManager.methodCalls.isEmpty, "\(fileManager.methodCalls)")
    }

    func test_flushesStdoutWhenUsingAnXcodeReporter() {
        options = .make(reportFormat: .xcode)

        sut.handle(.newMutationTestOutcomeAvailable(.passedMutant))

        XCTAssertTrue(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAJsonReporter() {
        options = .make(reportFormat: .json)

        sut.handle(.newMutationTestOutcomeAvailable(.passedMutant))

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAPlainTextReporter() {
        options = .make(reportFormat: .plain)

        sut.handle(.newMutationTestOutcomeAvailable(.passedMutant))

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    // Without --verbose, the Logger says how many Swift files and mutants it found, and lists none.
    func test_discovery_withoutVerbose_listsNothing() throws {
        try sut.start()

        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 1 Swift files",
            "✅ In total, SwiftMutator discovered 0 mutants in 0 files",
        ])
    }

    // --verbose reaches the Logger, which then lists each Swift file it found, and how many mutants each file has.
    func test_discovery_withVerbose_listsEachFile() throws {
        options = .make(verbose: true)
        try sut.start()

        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 1 Swift files\n\n" + "a.swift".bold,
            "✅ In total, SwiftMutator discovered 0 mutants in 0 files\n",
        ])
    }

    func test_whyThePackagesSourceFilesCouldntBeListed_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(.packageSourceFilesUnavailable(reason: "/usr/bin/swift couldn't be started"))

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            printer.linesPassed.first?.hasPrefix(
                        "⚠️ SwiftMutator couldn't tell which files the package's targets compile: "
                            + "/usr/bin/swift couldn't be started.\n"
                    ),
            true,
            "\(printer.linesPassed)"
        )
    }

    func test_whyTheBuildConditionsCouldntBeHad_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(.buildConditionsUnavailable(reason: "xcodebuild reported no build settings"))

        XCTAssertEqual(printer.linesPassed, [
            """
            ℹ️ SwiftMutator couldn't tell which `#if` branches the build compiles: xcodebuild reported no build settings.
            Every branch keeps its mutants, unless coverage shows that the build left it out.
            """,
        ])
    }

    func test_mutantsInInactiveIfs_areCountedApartFromThoseWithNoPlaceForASwitch() throws {
        try sut.start()

        runEvents.send(.mutantsDropped([
            droppedMutant(line: 1, reason: .noPlaceForASwitch),
            droppedMutant(line: 2, reason: .inInactiveIfConfig),
            droppedMutant(line: 3, reason: .inInactiveIfConfig),
        ]))

        XCTAssertEqual(printer.linesPassed, [
            "ℹ️ SwiftMutator left out 1 mutant with nowhere to put a switch, so no report covers it. "
                + "--verbose lists them.",
            "ℹ️ SwiftMutator left out 2 mutants in `#if` branches this build doesn't compile, so no report covers them. "
                + "--verbose lists them.",
        ])
    }

    func test_mutantsInInactiveIfs_withVerbose_areListed() throws {
        options = .make(verbose: true)
        try sut.start()

        runEvents.send(.mutantsDropped([droppedMutant(line: 2, reason: .inInactiveIfConfig)]))

        XCTAssertEqual(printer.linesPassed, [
            "ℹ️ SwiftMutator left out 1 mutant in `#if` branches this build doesn't compile, so no report covers it:",
            "Sources/App.swift:2:3 RelationalOperatorReplacement: in an `#if` branch this build doesn't compile",
        ])
    }

    private func droppedMutant(line: Int, reason: DroppedMutant.Reason) -> DroppedMutant {
        DroppedMutant(
            path: "Sources/App.swift",
            mutationOperatorId: .ror,
            position: MutationPosition(utf8Offset: 0, line: line, column: 3),
            snapshot: .null,
            lines: line...line,
            reason: reason
        )
    }

    func test_whyCoverageFailed_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(
            .projectCoverageDiscoveryFinished(CoverageFailure(reason: "llvm-cov failed", log: "/logs/coverage run.log"))
        )
        runEvents.send(.projectCoverageDiscoveryFinished(nil))

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            printer.linesPassed.first?.hasPrefix(
                        "❌ Gathering coverage failed: llvm-cov failed.\n"
                            + "The coverage run's output is in \("/logs/coverage run.log".bold)\n"
                    ),
            true
        )
    }

    func test_testsThatFailedWithCoverageOn_reachTheLogger() throws {
        try sut.start()

        runEvents.send(
            .projectCoverageTestsFailed(TestsFailedWithCoverage(
                tests: .init(tests: [.init(name: "sum()", location: nil)], total: 1, firstLine: nil),
                log: nil
            ))
        )

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ 1 test failed with coverage on, but coverage was still gathered from every test process:
              sum()
            Code a failed test would have run after it stopped reads as never run, so its mutants aren't tested.
            """,
        ])
    }

    // The step that ran each test keeps its log, by moving the file the run wrote (`FileSystemManager.keepLog`), so
    // the observer writes none: a second write of every log would double what a run writes to disk.
    func test_aTestLog_isNotWrittenByTheObserver() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let mutationPoint = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "/project/Sources/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )

        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(
                testLog: "Executed 3 tests, with 0 failures",
                timePerBuildTestCycle: 1,
                remainingMutationPointsCount: 1
            ))
        )
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(
                mutationPoint: mutationPoint,
                testLog: "Executed 3 tests, with 1 failure",
                keptFileName: "RemoveSideEffects @ file2.swift-5-6 9c3e04a1d8f2b7e6 (#2).log"
            ))
        )

        XCTAssertFalse(
            fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"), "\(fileManager.methodCalls)"
        )
    }

    // The step keeps its log beside the first run's.
    func test_aRerun_isSaid_withoutCountingTheProgress() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let point = MutationPoint.make(filePath: "/project/Sources/Sum.swift", position: 3)
        let keptFileName = "RelationalOperatorReplacement @ Sum.swift-3-3 670192af8b34c2a4 (rerun).log"

        runEvents.send(
            .timeoutRerunFinished(TimeoutRerun(
                rerun: .make(testSuiteOutcome: .failed, point: point),
                log: .make(
                    mutationPoint: point, testLog: "Executed 3 tests, with 1 failure", keptFileName: keptFileName
                ),
                seconds: 12,
                number: 1,
                count: 1
            ))
        )

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(printer.linesPassed, ["🔁 1 of 1 killed at Sum.swift:3:3, in 12 s"])
    }

    // The step keeps the first run's log beside the log of the run that replaced it, which the mutant's line names.
    // Neither is counted in the progress.
    func test_aRunRepeatedAfterALaunchFailure_isSaid_namingTheFirstRunsLog() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let point = MutationPoint.make(filePath: "/project/Sources/Sum.swift", position: 3)
        let keptFileName = "RelationalOperatorReplacement @ Sum.swift-3-3 670192af8b34c2a4 (launch failed).log"

        runEvents.send(
            .runRepeatedAfterLaunchFailure(RepeatedRun(
                mutant: .make(testSuiteOutcome: .failed, point: point),
                worker: 1,
                line: "Simulator device failed to launch com.example.App.",
                log: .make(mutationPoint: point, testLog: "** TEST EXECUTE FAILED **", keptFileName: keptFileName)
            ))
        )

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertTrue(printer.linesPassed[0].hasPrefix("🔁 The simulator didn't launch the tests for Sum.swift:3:3"))
    }

    // The step keeps the first run's log beside the log of the baseline that replaced it, before any progress.
    func test_aBaselineRepeatedAfterALaunchFailure_isSaid_namingTheFirstRunsLog() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        try sut.start()
        let keptFileName = "baseline run (launch failed).log"

        runEvents.send(.baselineRepeatedAfterLaunchFailure(
            line: "Simulator device failed to launch com.example.App.",
            log: .make(testLog: "** TEST FAILED **", keptFileName: keptFileName)
        ))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(printer.linesPassed, [
            "🔁 The simulator didn't launch the baseline's tests, so they ran again. "
                + "The first run's log, baseline run (launch failed).log, says: "
                + "Simulator device failed to launch com.example.App.",
        ])
    }

    // The first run's timeout wasn't a survivor the Xcode format warns of, so a rerun that survives is warned of
    // then. One that timed out again changed nothing.
    func test_aTimeoutThatSurvivesItsRerun_isWarnedOf_inTheXcodeFormat() throws {
        options = .make(reportFormat: .xcode)
        try sut.start()
        let point = MutationPoint.make(filePath: "/project/Sources/Sum.swift", position: 3)
        let rerun = { (outcome: TestSuiteOutcome) in
            TimeoutRerun(
                rerun: .make(testSuiteOutcome: outcome, point: point), log: .make(), seconds: 12, number: 1, count: 2
            )
        }

        runEvents.send(.timeoutRerunFinished(rerun(.timeout)))
        XCTAssertEqual(printer.linesPassed.filter { $0.contains("warning:") }, [])
        runEvents.send(.timeoutRerunFinished(rerun(.passed)))

        XCTAssertEqual(printer.linesPassed.filter { $0.contains("warning:") }.count, 1, "\(printer.linesPassed)")
        XCTAssertTrue(flushStandardOut.flushHandlerWasCalled)
    }

    func test_configurationKeysUnknown_isPrinted() throws {
        try sut.start()

        runEvents.send(
            .configurationKeysUnknown(
                [.init(key: "mutationTestTimeOut", closest: "mutationTestTimeout")],
                file: "ci.yml"
            )
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ ci.yml: \("mutationTestTimeOut".bold) isn't a configuration key, so it is ignored. "
                + "Did you mean \("mutationTestTimeout".bold)?"
        )
    }

    func test_stopAtFirstFailureTurnedOff_isPrinted() throws {
        try sut.start()

        runEvents.send(.stopAtFirstFailureTurnedOff(reason: "the reason"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: the reason"
        )
    }

    func test_workersShareUserDefaults_isPrinted() throws {
        try sut.start()

        runEvents.send(.workersShareUserDefaults)

        XCTAssertEqual(
            printer.linesPassed.last,
            "ℹ️ Workers running through `swift test` share `UserDefaults.standard`: tests that write to it can fail "
                + "each other and kill mutants they don't check. See \"Tests that share state across workers\" in "
                + "the README."
        )
    }

    func test_resumePlanned_reachesTheLogger() throws {
        try sut.start()

        runEvents.send(
            .resumePlanned(
                ResumeSummary.make(
                    path: "/logs/results.jsonl",
                    reused: 3,
                    toTest: 1,
                    retestedBecause: [.buildError: 1]
                )
            )
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 3 results still hold, "
                + "so 1 mutant is left to test (1 build error)."
        )
    }

    // The time left is the rate since the mutants started, which the Logger only knows from this event. Without
    // it, the bar would show its first estimate until 100%.
    func test_mutantRunsStarted_reachesTheLogger() throws {
        let milliseconds = Locked<UInt64>(1_000_000)
        current.instant = { DispatchTime(uptimeNanoseconds: milliseconds.value * 1_000_000) }
        try sut.start()
        runEvents.send(.resumePlanned(ResumeSummary.make(reused: 0, toTest: 10, retestedBecause: [.notRecorded: 10])))
        // 10 mutants, 120 s each, on one worker.
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(timePerBuildTestCycle: 120, remainingMutationPointsCount: 10))
        )

        runEvents.send(.mutantRunsStarted)
        milliseconds.change { $0 += 60_000 }
        runEvents.send(.newTestLogAvailable(MutationTestLog.make(mutationPoint: .make())))

        let draw = printer.linesPassed.last { $0.contains("ETC:") } ?? ""
        // 60 s a mutant, and 9 left. The first estimate would say 20 min.
        XCTAssertTrue(draw.hasSuffix("ETC: 9 min"), draw)
    }

    // Without a terminal, each mutant's result is a line of progress, which the Logger only gets from this event.
    func test_aMutantsOutcome_reachesTheLogger_forItsLineOfProgress() throws {
        current.standardOutIsATerminal = false
        try sut.start()
        runEvents.send(.resumePlanned(ResumeSummary.make(reused: 0, toTest: 2, retestedBecause: [.notRecorded: 2])))
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2))
        )

        runEvents.send(.newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation.make()))

        let line = printer.linesPassed.last ?? ""
        XCTAssertTrue(line.hasPrefix("[02:42:00] 1 of 2 (50%) | 1 survived | "), line)
    }

    func test_resultsFileCreated_isLogged_andNamedAtTheEnd() throws {
        try sut.start()

        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)"
        )

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.make()))

        XCTAssertEqual(printer.linesPassed.last, "💾 Each mutant's result is in \("/logs/results.jsonl".bold)")
    }

    // Beside the results file, with how the run ended and where its report went: a finished run's, and a stopped
    // one's with its partial report.
    func test_aRunsEnd_writesItsSummaryBesideTheResultsFile() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed), .make()])

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertEqual(writeFile.pathPassed, "/logs/summary.json")
        let finished = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertEqual(finished, RunSummary(of: outcome, ended: .finished, report: "/out/report.txt"))

        runEvents.send(.mutationTestingEndedEarly(.make(reason: .aborted, detail: "tooManyBuildErrors")))

        let stopped = try JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
        XCTAssertEqual(stopped.ended, .aborted)
        XCTAssertEqual(stopped.endDetail, "tooManyBuildErrors")
        XCTAssertEqual(stopped.report, "/out/report.partial.txt")
        XCTAssertEqual(stopped.mutants, 2)
    }

    // The file then lacks every result after the failed write, which the warning said.
    func test_aResultsFileThatCouldNotBeWritten_isNotNamedAtTheEnd() throws {
        try sut.start()

        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        runEvents.send(.resultsFileUnavailable(reason: "can't write to /logs/results.jsonl: No space left on device"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ SwiftMutator can't save each mutant's result as it goes: "
                + "can't write to /logs/results.jsonl: No space left on device. "
                + "The report at the end doesn't depend on it."
        )

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.make()))

        XCTAssertFalse(
            printer.linesPassed.contains { $0.hasPrefix("💾 Each mutant's result") },
            "\(printer.linesPassed)"
        )
    }

    func test_aFinishedRun_savesItsReportAtTheRequestedPath_replacingAnOldOne() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed), .make()])
        try sut.start()
        fileManager.fileExistsToReturn = [true]

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertEqual(
            fileManager.methodCalls.suffix(3),
            ["fileExists(atPath:)", "removeItem(atPath:)", "createFile(atPath:contents:attributes:)"]
        )
        XCTAssertEqual(fileManager.paths.suffix(2), ["/out/report.txt", "/out/report.txt"])
        XCTAssertEqual(fileManager.contents, Data(PlainTextReporter().report(from: outcome).raw.utf8))
        // The report isn't printed, so its score is.
        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "📊 Mutation score: 50% (1 killed, 1 survived)",
            "📝 Report generated: \("/out/report.txt".bold)",
        ])
    }

    // Rainbow colours the plain report when standard output is a terminal, wherever the report goes: the file gets it
    // without the codes, and the terminal, without `-o`, with them.
    func test_aFinishedRunInATerminal_savesItsReportWithoutColourCodes() throws {
        let (outputTarget, enabled) = (Rainbow.outputTarget, Rainbow.enabled)
        Rainbow.outputTarget = .console
        Rainbow.enabled = true
        defer { (Rainbow.outputTarget, Rainbow.enabled) = (outputTarget, enabled) }
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed), .make()])
        let colouredReport = PlainTextReporter().report(from: outcome)
        try sut.start()

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertTrue(colouredReport.contains("\u{1B}["))
        let saved = try XCTUnwrap(fileManager.contents.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertFalse(saved.contains("\u{1B}"), saved)
        XCTAssertEqual(saved, colouredReport.raw)
    }

    // Without `-o` the report is printed, and there is no file to save it to.
    func test_aFinishedRunWithoutARequestedReport_savesNothing() throws {
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed), .make()])
        try sut.start()

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertFalse(
            fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"),
            "\(fileManager.methodCalls)"
        )
        XCTAssertEqual(
            printer.linesPassed.last,
            "📝 SwiftMutator's report\n\n\(PlainTextReporter().report(from: outcome))"
        )
    }

    // The warning the report gives of the run's suspect tests, after where the report went and before the results
    // file's line.
    func test_finished_passesTheSuspectWarningToTheLogger() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.withSuspectTests))

        XCTAssertEqual(printer.linesPassed.suffix(3), [
            "📝 Report generated: \("/out/report.txt".bold)",
            "⚠️ 2 tests may fail whatever the mutant: they failed for mutants in at least 15% of the 12 files with a "
                + "killed mutant (timing() in 12, order() in 10). Without their failures, the mutation score would be "
                + "at least 50%, not 92%.",
            "💾 Each mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    // A complete report from an earlier run is never replaced by a partial one.
    func test_anEarlyEnd_writesThePartialReportBesideTheRequestedOne() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        let earlyEnd = EarlyEnd.make(tested: [.failed, .passed])
        try sut.start()

        runEvents.send(.mutationTestingEndedEarly(earlyEnd))

        XCTAssertEqual(fileManager.paths.last, "/out/report.partial.txt")
        XCTAssertEqual(fileManager.contents, Data(PlainTextReporter().report(from: earlyEnd.outcome).raw.utf8))
        XCTAssertFalse(fileManager.paths.contains("/out/report.txt"), "\(fileManager.paths)")
    }

    func test_anEarlyEnd_writesThePartialReportInTheRequestedFormat() throws {
        options = .make(reportFormat: .json, reportURL: URL(fileURLWithPath: "/out/report.json"))
        let earlyEnd = EarlyEnd.make(tested: [.failed, .passed])
        try sut.start()

        runEvents.send(.mutationTestingEndedEarly(earlyEnd))

        XCTAssertEqual(fileManager.paths.last, "/out/report.partial.json")
        let written = try JSONSerialization.jsonObject(with: XCTUnwrap(fileManager.contents)) as? [String: AnyHashable]
        let expected = try JSONSerialization.jsonObject(
            with: Data(JsonReporter().report(from: earlyEnd.outcome).utf8)
        ) as? [String: AnyHashable]
        XCTAssertNotNil(written)
        XCTAssertEqual(written, expected)
    }

    // Without `-o`, the summary and the results file say what was tested.
    func test_anEarlyEndWithoutARequestedReport_writesNoPartialReport() throws {
        try sut.start()

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [.failed, .passed])))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(
            standardError.linesPassed,
            ["⏹ Stopped by a signal after testing 2 of 4 mutants. Mutation score so far: 50%."]
        )
    }

    func test_anEarlyEndWithNothingTested_writesNoReport() throws {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        try sut.start()

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [])))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(standardError.linesPassed, ["⏹ Stopped by a signal before any of 4 mutants finished."])
    }

    func test_anEarlyEnd_printsItsSummaryToStandardError_namingTheResultsFile() throws {
        current.commandLineArguments = ["run", "-o", "/out/report.txt"]
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        let printedBefore = printer.linesPassed

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(detail: "SIGINT", tested: [.failed, .passed])))

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "📝 Partial report: \("/out/report.partial.txt".bold)",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "▶️ Continue: swift-mutator run -o /out/report.txt --resume '/logs/results.jsonl'",
        ])
        XCTAssertEqual(printer.linesPassed, printedBefore, "nothing more on standard output")
    }

    // The command repeats the arguments SwiftMutator was started with, so the run goes on as it was asked to.
    func test_continueCommand_comesFromTheCommandLine() throws {
        current.commandLineArguments = [
            "--skip-coverage", "--format", "json", "--operators", "RelationalOperatorReplacement",
        ]
        options = .make(reportFormat: .json, mutationOperatorsList: [.ror], skipCoverage: true)
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/Oct 6, 2026 at 9:12 AM/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [.failed])))

        XCTAssertEqual(
            standardError.linesPassed.last,
            "▶️ Continue: swift-mutator --skip-coverage --format json --operators RelationalOperatorReplacement "
                + "--resume '/logs/Oct 6, 2026 at 9:12 AM/results.jsonl'"
        )
    }

    // A run from a test plan resumes with the same plan, named as it was given: the plan runs from the project folder.
    // A --plan-ignoring stays, as every session checks the project against the plan.
    func test_aTestPlanRun_getsAContinueLine_repeatingThePlanPath() throws {
        current.commandLineArguments = [
            "run-without-mutating", "muter-mappings.json", "--plan-ignoring", "Tests/*",
        ]
        options = .make(
            testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"),
            planIgnoring: ["Tests/*"]
        )
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(detail: "SIGINT", tested: [.failed, .passed])))

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "▶️ Continue: swift-mutator run-without-mutating muter-mappings.json --plan-ignoring 'Tests/*' "
                + "--resume '/logs/results.jsonl'",
        ])
    }

    // No run continues one of a single mutant: the same command tests it again.
    func test_aOneMutantRun_getsNoContinueLine() throws {
        current.commandLineArguments = ["run", "--mutant", "Bar.swift:12:9"]
        options = .make(mutant: MutantReference(path: "Bar.swift", line: 12, column: 9))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(detail: "SIGINT", tested: [.failed])))

        XCTAssertEqual(
            standardError.linesPassed.last,
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "\(standardError.linesPassed)"
        )
        XCTAssertFalse(standardError.linesPassed.contains { $0.contains("Continue") }, "\(standardError.linesPassed)")
    }

    // A run of one mutant ends with what it changes, its log and its verdict, not a report of a score of one mutant.
    func test_aOneMutantRun_printsItsBlockInPlaceOfTheReport() throws {
        options = .make(mutant: MutantReference(path: "Bar.swift", line: 12, column: 9))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        let printedBefore = printer.linesPassed.count

        runEvents.send(.oneMutantTested(.make()))
        runEvents.send(
            .mutationTestingFinished(MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed)]))
        )

        let printed = Array(printer.linesPassed.dropFirst(printedBefore))
        XCTAssertEqual(printed.first, "🏁 SwiftMutator finished running!")
        XCTAssertEqual(printed.dropFirst().first, "🔬 Sources/Foo/Bar.swift:12:9 SwapTernary (swapped ternary operator)")
        XCTAssertTrue(printed.contains("Verdict: killed by picksB() (1 failed test), in 4.2 s"), "\(printed)")
        XCTAssertFalse(printed.contains { $0.contains("SwiftMutator's report") }, "\(printed)")
        XCTAssertEqual(printed.last, "💾 Each mutant's result is in \("/logs/results.jsonl".bold)")
        XCTAssertFalse(
            fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"),
            "\(fileManager.methodCalls)"
        )
    }

    // A report asked for with -o is still written, and its line follows the block.
    func test_aOneMutantRun_stillSavesARequestedReport() throws {
        options = .make(
            reportURL: URL(fileURLWithPath: "/out/report.txt"),
            mutant: MutantReference(path: "Bar.swift", line: 12, column: 9)
        )
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed)])
        try sut.start()

        runEvents.send(.oneMutantTested(.make()))
        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertEqual(fileManager.contents, Data(PlainTextReporter().report(from: outcome).raw.utf8))
        XCTAssertEqual(printer.linesPassed.last, "📝 Report generated: \("/out/report.txt".bold)")
    }

    // The file lacks every result after the failed write.
    func test_anEarlyEnd_doesNotNameAResultsFileThatCouldNotBeWritten() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        runEvents.send(.resultsFileUnavailable(reason: "No space left on device"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [.failed])))

        XCTAssertEqual(
            standardError.linesPassed,
            ["⏹ Stopped by a signal after testing 1 of 4 mutants. Mutation score so far: 100%."]
        )
    }

    // From the moment the run claims its folder, it holds the marker there, so no other run prunes the folder. A run
    // that kept nothing else there removes the folder, marker and all.
    func test_start_holdsTheRunsMarker_andAFolderHoldingOnlyItIsRemoved() throws {
        let project = try makeTemporaryDirectory() + "/project"
        current.fileManager = FileManagerIn(directory: project)
        try sut.start()
        let marker = sut.loggingDirectory + "/" + RunMarker.fileName

        XCTAssertTrue(sut.loggingDirectory.hasPrefix(project + "_muter_logs/"), sut.loggingDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sut.loggingDirectory), [RunMarker.fileName])
        XCTAssertEqual(ResultsFile.probeLock(marker), .inUse, "held by the run")

        sut.removeLoggingDirectoryIfEmpty()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sut.loggingDirectory))
    }

    // A kept log keeps the folder, and the marker in it, whose lock goes only with the run.
    func test_aLogFolderWithAKeptLog_keepsItsMarker() throws {
        let project = try makeTemporaryDirectory() + "/project"
        current.fileManager = FileManagerIn(directory: project)
        try sut.start()
        try Data("log".utf8).write(to: URL(fileURLWithPath: sut.loggingDirectory + "/baseline run.log"))

        sut.removeLoggingDirectoryIfEmpty()

        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: sut.loggingDirectory)),
            [RunMarker.fileName, "baseline run.log"]
        )
        XCTAssertEqual(ResultsFile.probeLock(sut.loggingDirectory + "/" + RunMarker.fileName), .inUse)
    }

    func test_prunedLogFolders_reachTheLogger() throws {
        try sut.start()

        runEvents.send(.logFoldersPruned(LogFolderPruning(
            root: "/p_muter_logs",
            keeping: 2,
            left: [.init(folders: ["Oct 1, 2026 at 8:12 AM"], reason: .inUse)]
        )))

        XCTAssertEqual(printer.linesPassed, [
            """
            🧹 Left the log folders of 1 earlier run in /p_muter_logs, beyond the newest 2 runs (keepLogFolders: 2):
            ⚠️ Left Oct 1, 2026 at 8:12 AM: another SwiftMutator run is using it.
            """,
        ])
    }
}

/// The real file manager, but for the current directory, which is `directory`.
private final class FileManagerIn: FileManager, @unchecked Sendable { // `directory` never changes
    private let directory: String

    init(directory: String) {
        self.directory = directory
        super.init()
    }

    override var currentDirectoryPath: String {
        directory
    }
}

private extension MutationTestOutcome.Mutation {
    static var passedMutant: Self {
        .make(
            testSuiteOutcome: .passed,
            point: .make(
                mutationOperatorId: .ror,
                filePath: "some/path",
                position: .firstPosition
            ),
            snapshot: .null
        )
    }
}
