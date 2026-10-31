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
    func test_discovery_withoutVerbose_listsNothing() {
        sut.start()

        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 1 Swift files",
            "✅ In total, SwiftMutator discovered 0 mutants in 0 files",
        ])
    }

    // --verbose reaches the Logger, which then lists each Swift file it found, and how many mutants each file has.
    func test_discovery_withVerbose_listsEachFile() {
        options = .make(verbose: true)
        sut.start()

        runEvents.send(.sourceFileDiscoveryFinished(["/p/a.swift"]))
        runEvents.send(.mutationsDiscoveryFinished([SchemataMutationMapping]()))

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 1 Swift files\n\n" + "a.swift".bold,
            "✅ In total, SwiftMutator discovered 0 mutants in 0 files\n",
        ])
    }

    func test_whyThePackagesSourceFilesCouldntBeListed_reachesTheLogger() {
        sut.start()

        runEvents.send(.packageSourceFilesUnavailable(reason: "/usr/bin/swift couldn't be started"))

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertTrue(
            printer.linesPassed.first?.hasPrefix(
                "⚠️ SwiftMutator couldn't tell which files the package's targets compile: "
                    + "/usr/bin/swift couldn't be started.\n"
            ) == true,
            "\(printer.linesPassed)"
        )
    }

    func test_whyCoverageFailed_reachesTheLogger() {
        sut.start()

        runEvents.send(
            .projectCoverageDiscoveryFinished(CoverageFailure(reason: "llvm-cov failed", log: "/logs/coverage run.log"))
        )
        runEvents.send(.projectCoverageDiscoveryFinished(nil))

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertTrue(
            printer.linesPassed.first?.hasPrefix(
                "❌ Gathering coverage failed: llvm-cov failed.\n"
                    + "The coverage run's output is in \("/logs/coverage run.log".bold)\n"
            ) == true
        )
    }

    func test_testsThatFailedWithCoverageOn_reachTheLogger() {
        sut.start()

        runEvents.send(
            .projectCoverageTestsFailed(TestsFailedWithCoverage(
                tests: .init(tests: [.init(name: "sum()", location: nil)], count: 1, firstLine: nil),
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

    // A failing baseline's log is the only record of why the run stopped: the abort message points the
    // user at the logs folder.
    func test_whenTheBaselineFails_itsLogIsWrittenToTheLoggingDirectory() {
        fileManager.currentDirectoryPathToReturn = "/project"
        sut.start()
        let loggingDirectory = sut.loggingDirectory

        runEvents.send(.baselineTestFailed(MutationTestLog.make(testLog: "error: no such module 'Calc'")))

        XCTAssertTrue(loggingDirectory.hasPrefix("/project_muter_logs/"), loggingDirectory)
        XCTAssertEqual(fileManager.paths.last, "\(loggingDirectory)/baseline run.log")
        XCTAssertEqual(fileManager.contents, Data("error: no such module 'Calc'".utf8))
    }

    // The name is the one the mutant's results line gives as its log.
    func test_eachTestLogIsWrittenToTheLoggingDirectory_underTheNameItCarries() {
        fileManager.currentDirectoryPathToReturn = "/project"
        sut.start()
        let loggingDirectory = sut.loggingDirectory
        let mutationPoint = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "/project/Sources/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )
        let keptFileName = "RemoveSideEffects @ file2.swift-5-6 9c3e04a1d8f2b7e6 (#2).log"

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
                keptFileName: keptFileName
            ))
        )

        XCTAssertEqual(fileManager.paths.suffix(2), [
            "\(loggingDirectory)/baseline run.log",
            "\(loggingDirectory)/\(keptFileName)",
        ])
        XCTAssertEqual(fileManager.contents, Data("Executed 3 tests, with 1 failure".utf8))
    }

    func test_stopAtFirstFailureTurnedOff_isPrinted() {
        sut.start()

        runEvents.send(.stopAtFirstFailureTurnedOff(reason: "the reason"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: the reason"
        )
    }

    func test_resumePlanned_reachesTheLogger() {
        sut.start()

        runEvents.send(
            .resumePlanned(ResumeSummary.make(path: "/logs/results.jsonl", reused: 3, toTest: 1, retestedBecause: [.buildError: 1]))
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 3 results still hold, "
                + "so 1 mutant is left to test (1 build error)."
        )
    }

    // The time left is the rate since the mutants started, which the Logger only knows from this event. Without
    // it, the bar would show its first estimate until 100%.
    func test_mutantRunsStarted_reachesTheLogger() {
        let milliseconds = Locked<UInt64>(1_000_000)
        current.instant = { DispatchTime(uptimeNanoseconds: milliseconds.value * 1_000_000) }
        sut.start()
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
    func test_aMutantsOutcome_reachesTheLogger_forItsLineOfProgress() {
        current.standardOutIsATerminal = false
        sut.start()
        runEvents.send(.resumePlanned(ResumeSummary.make(reused: 0, toTest: 2, retestedBecause: [.notRecorded: 2])))
        runEvents.send(
            .newTestLogAvailable(MutationTestLog.make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 2))
        )

        runEvents.send(.newMutationTestOutcomeAvailable(MutationTestOutcome.Mutation.make()))

        let line = printer.linesPassed.last ?? ""
        XCTAssertTrue(line.hasPrefix("[02:42:00] 1 of 2 (50%) | 1 survived | "), line)
    }

    func test_resultsFileCreated_isLogged_andNamedAtTheEnd() {
        sut.start()

        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)"
        )

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.make()))

        XCTAssertEqual(printer.linesPassed.last, "💾 Each mutant's result is in \("/logs/results.jsonl".bold)")
    }

    // The file then lacks every result after the failed write, which the warning said.
    func test_aResultsFileThatCouldNotBeWritten_isNotNamedAtTheEnd() {
        sut.start()

        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        runEvents.send(.resultsFileUnavailable(reason: "can't write to /logs/results.jsonl: No space left on device"))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ SwiftMutator can't save each mutant's result as it goes: "
                + "can't write to /logs/results.jsonl: No space left on device. "
                + "The report at the end doesn't depend on it."
        )

        runEvents.send(.mutationTestingFinished(MutationTestOutcome.make()))

        XCTAssertFalse(printer.linesPassed.contains { $0.hasPrefix("💾 Each mutant's result") }, "\(printer.linesPassed)")
    }

    func test_aFinishedRun_savesItsReportAtTheRequestedPath_replacingAnOldOne() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed), .make()])
        sut.start()
        fileManager.fileExistsToReturn = [true]

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertEqual(
            fileManager.methodCalls.suffix(3),
            ["fileExists(atPath:)", "removeItem(atPath:)", "createFile(atPath:contents:attributes:)"]
        )
        XCTAssertEqual(fileManager.paths.suffix(2), ["/out/report.txt", "/out/report.txt"])
        XCTAssertEqual(fileManager.contents, Data(PlainTextReporter().report(from: outcome).raw.utf8))
        XCTAssertEqual(printer.linesPassed.last, "📝 Report generated: \("/out/report.txt".bold)")
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
        sut.start()

        runEvents.send(.mutationTestingFinished(outcome))

        XCTAssertTrue(colouredReport.contains("\u{1B}["))
        let saved = try XCTUnwrap(fileManager.contents.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertFalse(saved.contains("\u{1B}"), saved)
        XCTAssertEqual(saved, colouredReport.raw)
    }

    // Without `-o` the report is printed, and there is no file to save it to.
    func test_aFinishedRunWithoutARequestedReport_savesNothing() {
        let outcome = MutationTestOutcome.make(mutations: [.make(testSuiteOutcome: .failed), .make()])
        sut.start()

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
    func test_finished_passesTheSuspectWarningToTheLogger() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        sut.start()
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
    func test_anEarlyEnd_writesThePartialReportBesideTheRequestedOne() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        let earlyEnd = EarlyEnd.make(tested: [.failed, .passed])
        sut.start()

        runEvents.send(.mutationTestingEndedEarly(earlyEnd))

        XCTAssertEqual(fileManager.paths.last, "/out/report.partial.txt")
        XCTAssertEqual(fileManager.contents, Data(PlainTextReporter().report(from: earlyEnd.outcome).raw.utf8))
        XCTAssertFalse(fileManager.paths.contains("/out/report.txt"), "\(fileManager.paths)")
    }

    func test_anEarlyEnd_writesThePartialReportInTheRequestedFormat() throws {
        options = .make(reportFormat: .json, reportURL: URL(fileURLWithPath: "/out/report.json"))
        let earlyEnd = EarlyEnd.make(tested: [.failed, .passed])
        sut.start()

        runEvents.send(.mutationTestingEndedEarly(earlyEnd))

        XCTAssertEqual(fileManager.paths.last, "/out/report.partial.json")
        let written = try JSONSerialization.jsonObject(with: XCTUnwrap(fileManager.contents)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(
            with: Data(JsonReporter().report(from: earlyEnd.outcome).utf8)
        ) as? NSDictionary
        XCTAssertNotNil(written)
        XCTAssertEqual(written, expected)
    }

    // Without `-o`, the summary and the results file say what was tested.
    func test_anEarlyEndWithoutARequestedReport_writesNoPartialReport() {
        sut.start()

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [.failed, .passed])))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(
            standardError.linesPassed,
            ["⏹ Stopped by a signal after testing 2 of 4 mutants. Mutation score so far: 50%."]
        )
    }

    func test_anEarlyEndWithNothingTested_writesNoReport() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        sut.start()

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [])))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(standardError.linesPassed, ["⏹ Stopped by a signal before any of 4 mutants finished."])
    }

    func test_anEarlyEnd_printsItsSummaryToStandardError_namingTheResultsFile() {
        current.commandLineArguments = ["run", "-o", "/out/report.txt"]
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        sut.start()
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
    func test_continueCommand_comesFromTheCommandLine() {
        current.commandLineArguments = ["--skip-coverage", "--format", "json", "--operators", "RelationalOperatorReplacement"]
        options = .make(reportFormat: .json, mutationOperatorsList: [.ror], skipCoverage: true)
        sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/Oct 6, 2026 at 9:12 AM/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [.failed])))

        XCTAssertEqual(
            standardError.linesPassed.last,
            "▶️ Continue: swift-mutator --skip-coverage --format json --operators RelationalOperatorReplacement "
                + "--resume '/logs/Oct 6, 2026 at 9:12 AM/results.jsonl'"
        )
    }

    // A run from a test plan can't be resumed: its results file still makes a report.
    func test_aTestPlanRun_getsNoContinueLine() {
        current.commandLineArguments = ["run-without-mutating", "muter-mappings.json"]
        options = .make(testPlanURL: URL(fileURLWithPath: "/project/muter-mappings.json"))
        sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(detail: "SIGINT", tested: [.failed, .passed])))

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
        ])
    }

    // The file lacks every result after the failed write.
    func test_anEarlyEnd_doesNotNameAResultsFileThatCouldNotBeWritten() {
        sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))
        runEvents.send(.resultsFileUnavailable(reason: "No space left on device"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd.make(tested: [.failed])))

        XCTAssertEqual(
            standardError.linesPassed,
            ["⏹ Stopped by a signal after testing 1 of 4 mutants. Mutation score so far: 100%."]
        )
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
