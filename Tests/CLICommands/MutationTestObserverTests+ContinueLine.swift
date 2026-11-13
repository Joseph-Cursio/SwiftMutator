@testable import muterCore
import XCTest

extension MutationTestObserverTests {
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
}
