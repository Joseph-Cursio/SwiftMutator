@testable import muterCore
import Rainbow
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

        sut.handleNewMutationTestOutcomeAvailable(notification: .make())

        XCTAssertTrue(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAJsonReporter() {
        options = .make(reportFormat: .json)

        sut.handleNewMutationTestOutcomeAvailable(notification: .make())

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    func test_doesntFlushStdoutWhenUsingAPlainTextReporter() {
        options = .make(reportFormat: .plain)

        sut.handleNewMutationTestOutcomeAvailable(notification: .make())

        XCTAssertFalse(flushStandardOut.flushHandlerWasCalled)
    }

    func test_logFileNameUsingAPlainTextReporter() {
        options = .make(reportFormat: .plain)

        XCTAssertEqual(sut.logFileName(from: nil), "baseline run.log")
    }

    func test_logFileNameUsingAXcodeReporter() {
        options = .make(reportFormat: .xcode)

        let mutationPoint1 = MutationPoint(
            mutationOperatorId: .ror,
            filePath: "~/user/file.swift",
            position: .firstPosition
        )

        let mutationPoint2 = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "~/user/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )

        XCTAssertEqual(
            sut.logFileName(from: mutationPoint1),
            "RelationalOperatorReplacement @ file.swift-0-0.log"
        )

        XCTAssertEqual(
            sut.logFileName(from: mutationPoint2),
            "RemoveSideEffects @ file2.swift-5-6.log"
        )
    }

    // A failing baseline's log is the only record of why the run stopped: the abort message points the
    // user at the logs folder.
    func test_whenTheBaselineFails_itsLogIsWrittenToTheLoggingDirectory() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        sut.start()
        let loggingDirectory = try XCTUnwrap(fileManager.paths.first)

        notificationCenter.post(
            name: .baselineTestFailed,
            object: MutationTestLog.make(testLog: "error: no such module 'Calc'")
        )

        XCTAssertTrue(loggingDirectory.hasPrefix("/project_muter_logs/"), loggingDirectory)
        XCTAssertEqual(fileManager.paths.last, "\(loggingDirectory)/baseline run.log")
        XCTAssertEqual(fileManager.contents, Data("error: no such module 'Calc'".utf8))
    }

    func test_eachTestLogIsWrittenToTheLoggingDirectory_namedAfterItsMutant() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        sut.start()
        let loggingDirectory = try XCTUnwrap(fileManager.paths.first)
        let mutationPoint = MutationPoint(
            mutationOperatorId: .removeSideEffects,
            filePath: "/project/Sources/file2.swift",
            position: MutationPosition(utf8Offset: 2, line: 5, column: 6)
        )

        notificationCenter.post(
            name: .newTestLogAvailable,
            object: MutationTestLog.make(
                testLog: "Executed 3 tests, with 0 failures",
                timePerBuildTestCycle: 1,
                remainingMutationPointsCount: 1
            )
        )
        notificationCenter.post(
            name: .newTestLogAvailable,
            object: MutationTestLog.make(mutationPoint: mutationPoint, testLog: "Executed 3 tests, with 1 failure")
        )

        XCTAssertEqual(fileManager.paths.suffix(2), [
            "\(loggingDirectory)/baseline run.log",
            "\(loggingDirectory)/RemoveSideEffects @ file2.swift-5-6.log",
        ])
        XCTAssertEqual(fileManager.contents, Data("Executed 3 tests, with 1 failure".utf8))
    }

    func test_stopAtFirstFailureTurnedOff_isPrinted() {
        sut.start()

        notificationCenter.post(name: .stopAtFirstFailureTurnedOff, object: "the reason")

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: the reason"
        )
    }

    func test_resultsFileCreated_isLogged_andNamedAtTheEnd() {
        sut.start()

        notificationCenter.post(name: .resultsFileCreated, object: "/logs/results.jsonl")

        XCTAssertEqual(
            printer.linesPassed.last,
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)"
        )

        notificationCenter.post(name: .mutationTestingFinished, object: MutationTestOutcome.make())

        XCTAssertEqual(printer.linesPassed.last, "💾 Each mutant's result is in \("/logs/results.jsonl".bold)")
    }

    // The file then lacks every result after the failed write, which the warning said.
    func test_aResultsFileThatCouldNotBeWritten_isNotNamedAtTheEnd() {
        sut.start()

        notificationCenter.post(name: .resultsFileCreated, object: "/logs/results.jsonl")
        notificationCenter.post(
            name: .resultsFileUnavailable,
            object: "can't write to /logs/results.jsonl: No space left on device"
        )

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ SwiftMutator can't save each mutant's result as it goes: "
                + "can't write to /logs/results.jsonl: No space left on device. "
                + "The report at the end doesn't depend on it."
        )

        notificationCenter.post(name: .mutationTestingFinished, object: MutationTestOutcome.make())

        XCTAssertFalse(printer.linesPassed.contains { $0.hasPrefix("💾 Each mutant's result") }, "\(printer.linesPassed)")
    }

    // A complete report from an earlier run is never replaced by a partial one.
    func test_anEarlyEnd_writesThePartialReportBesideTheRequestedOne() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        let earlyEnd = EarlyEnd.make(tested: [.failed, .passed])
        sut.start()

        notificationCenter.post(name: .mutationTestingEndedEarly, object: earlyEnd)

        XCTAssertEqual(fileManager.paths.last, "/out/report.partial.txt")
        XCTAssertEqual(fileManager.contents, Data(PlainTextReporter().report(from: earlyEnd.outcome).utf8))
        XCTAssertFalse(fileManager.paths.contains("/out/report.txt"), "\(fileManager.paths)")
    }

    func test_anEarlyEnd_writesThePartialReportInTheRequestedFormat() throws {
        options = .make(reportFormat: .json, reportURL: URL(fileURLWithPath: "/out/report.json"))
        let earlyEnd = EarlyEnd.make(tested: [.failed, .passed])
        sut.start()

        notificationCenter.post(name: .mutationTestingEndedEarly, object: earlyEnd)

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

        notificationCenter.post(name: .mutationTestingEndedEarly, object: EarlyEnd.make(tested: [.failed, .passed]))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(
            standardError.linesPassed,
            ["⏹ Stopped by a signal after testing 2 of 4 mutants. Mutation score so far: 50%."]
        )
    }

    func test_anEarlyEndWithNothingTested_writesNoReport() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        sut.start()

        notificationCenter.post(name: .mutationTestingEndedEarly, object: EarlyEnd.make(tested: []))

        XCTAssertFalse(fileManager.methodCalls.contains("createFile(atPath:contents:attributes:)"))
        XCTAssertEqual(standardError.linesPassed, ["⏹ Stopped by a signal before any of 4 mutants finished."])
    }

    func test_anEarlyEnd_printsItsSummaryToStandardError_namingTheResultsFile() {
        options = .make(reportURL: URL(fileURLWithPath: "/out/report.txt"))
        sut.start()
        notificationCenter.post(name: .resultsFileCreated, object: "/logs/results.jsonl")
        let printedBefore = printer.linesPassed

        notificationCenter.post(
            name: .mutationTestingEndedEarly,
            object: EarlyEnd.make(detail: "SIGINT", tested: [.failed, .passed])
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "📝 Partial report: \("/out/report.partial.txt".bold)",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
        ])
        XCTAssertEqual(printer.linesPassed, printedBefore, "nothing more on standard output")
    }

    // The file lacks every result after the failed write.
    func test_anEarlyEnd_doesNotNameAResultsFileThatCouldNotBeWritten() {
        sut.start()
        notificationCenter.post(name: .resultsFileCreated, object: "/logs/results.jsonl")
        notificationCenter.post(name: .resultsFileUnavailable, object: "No space left on device")

        notificationCenter.post(name: .mutationTestingEndedEarly, object: EarlyEnd.make(tested: [.failed]))

        XCTAssertEqual(
            standardError.linesPassed,
            ["⏹ Stopped by a signal after testing 1 of 4 mutants. Mutation score so far: 100%."]
        )
    }
}

private extension Notification {
    static func make() -> Notification {
        Notification(
            name: .newMutationTestOutcomeAvailable,
            object: MutationTestOutcome.Mutation.make(
                testSuiteOutcome: .passed,
                point: .make(
                    mutationOperatorId: .ror,
                    filePath: "some/path",
                    position: .firstPosition
                ),
                snapshot: .null
            ),
            userInfo: nil
        )
    }
}
