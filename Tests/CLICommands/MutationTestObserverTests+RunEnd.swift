@testable import muterCore
// Rainbow's settings are static vars that nothing guards: `@preconcurrency` lets these tests change them unchecked,
// which is safe because XCTest runs these tests one at a time on the main thread.
@preconcurrency import Rainbow
import XCTest

extension MutationTestObserverTests {
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
}
