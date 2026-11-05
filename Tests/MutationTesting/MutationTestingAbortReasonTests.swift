@testable import muterCore
import TestingExtensions
import XCTest

final class MutationTestingAbortReasonTests: MuterTestCase {
    private let mutatedFilePath = "/project_mutated/Sources/Calc/Calc.swift"

    func test_whenAMutantCannotBeSwitchedOn_thenNameItAndWhy() {
        let description = MutationTestingAbortReason.mutantNotSwitchedOn(
            id: "Calc_ab12_RelationalOperatorReplacement_8_24_190",
            description: "The file “muter.xctestrun” couldn’t be saved."
        ).description

        XCTAssertTrue(description.contains("mutant Calc_ab12_RelationalOperatorReplacement_8_24_190"), description)
        XCTAssertTrue(description.contains("couldn’t be saved"), description)
        XCTAssertTrue(description.contains("rather than record a verdict"), description)
    }

    func test_whenAControlRunCannotSwitchTheMutantsOff_thenNameItAndWhy() {
        let description = MutationTestingAbortReason.controlRunNotSwitchedOff(
            number: 3,
            description: "The file “muter-worker1.xctestrun” couldn’t be saved."
        ).description

        XCTAssertTrue(description.contains("switch every mutant off for control run 3"), description)
        XCTAssertTrue(description.contains("couldn’t be saved"), description)
    }

    func test_whenASimulatorIsGone_thenNameTheWorkerWhatXcodebuildSaidAndTheLog_andHowToGoOn() {
        let line = "xcodebuild: error: Unable to find a device matching the provided destination specifier:"
        let description = MutationTestingAbortReason.simulatorUnavailable(
            worker: 2,
            line: line,
            log: "/logs/RelationalOperatorReplacement @ Sum.swift-3-5 670192af8b34c2a4 (simulator gone).log"
        ).description

        XCTAssertTrue(description.contains("the simulator that worker 2 tests mutants on is gone"), description)
        XCTAssertTrue(description.contains("  \(line)\n"), description)
        XCTAssertTrue(description.contains("log is in /logs/RelationalOperatorReplacement @ Sum.swift"), description)
        XCTAssertTrue(description.contains("Continue line"), description)

        let withoutALog = MutationTestingAbortReason.simulatorUnavailable(worker: 0, line: line, log: nil).description
        XCTAssertFalse(withoutALog.contains("log is in"), withoutALog)
    }

    func test_whenAWorkerClonesBaselineFailed_thenNameTheWorkerAndSuggestOneWorker() {
        let description = MutationTestingAbortReason.workerBaselineTestFailed(
            worker: 2,
            directory: "/project_mutated_worker2",
            log: "Test Case '-[CalcTests.FixtureTests test_roundTrip]' failed"
        ).description

        XCTAssertTrue(description.contains("parallel worker 2, at /project_mutated_worker2"), description)
        XCTAssertTrue(description.contains("mutationTestWorkers to 1"), description)
        XCTAssertTrue(description.contains("--workers 1"), description)
        XCTAssertTrue(description.contains("FixtureTests test_roundTrip"), description)
        XCTAssertFalse(
            description.contains("misconfiguring"),
            "The same command passed in the mutated project, so the configuration isn't to blame:\n\(description)"
        )
    }

    func test_whenBaselineFailedToCompileAMutatedFile_thenBlameSwiftMutatorAndNameTheFileAndError() {
        let log = """
        Building for debugging...
        /project_mutated/Sources/Calc/Calc.swift:8:24: error: expected expression after operator
        error: fatalError
        """

        let description = MutationTestingAbortReason.baselineTestFailed(
            log: log,
            mutatedFilePaths: [mutatedFilePath]
        ).description

        XCTAssertTrue(
            description.contains("Calc.swift:8:24: error: expected expression after operator"),
            description
        )
        XCTAssertTrue(description.contains("bug in SwiftMutator's own rewriting"), description)
        XCTAssertTrue(
            description.contains("Please report that bug at https://github.com/Joseph-Cursio/SwiftMutator/issues "),
            description
        )
        XCTAssertFalse(description.contains("muter-mutation-testing"), description)
        XCTAssertFalse(
            description.contains("misconfiguring"),
            "A rewritten file that doesn't compile is no fault of the configuration, so the message mustn't blame it:\n"
                + description
        )
    }

    func test_whenBaselineFailedWithACompileErrorInAFileSwiftMutatorDidNotMutate_thenKeepTheConfigurationHint() {
        let log = """
        /project_mutated/Tests/CalcTests/CalcTests.swift:4:1: error: no such module 'Calc'
        """

        let description = MutationTestingAbortReason.baselineTestFailed(
            log: log,
            mutatedFilePaths: [mutatedFilePath]
        ).description

        XCTAssertTrue(description.contains("misconfiguring"), description)
        XCTAssertFalse(description.contains("bug in SwiftMutator's own rewriting"), description)
        XCTAssertTrue(description.contains("no such module 'Calc'"), description)
    }

    func test_whenBaselineFailedWithATestFailure_thenKeepTheConfigurationHint() {
        let log = """
        Test Case '-[CalcTests.CalcTests test_inRange]' failed (0.001 seconds).
        Executed 2 tests, with 1 failure (0 unexpected) in 0.002 seconds
        """

        let description = MutationTestingAbortReason.baselineTestFailed(
            log: log,
            mutatedFilePaths: [mutatedFilePath]
        ).description

        XCTAssertTrue(description.contains("misconfiguring"), description)
        XCTAssertTrue(description.contains("test_inRange"), description)
        XCTAssertTrue(description.contains("SwiftMutator noticed that your test suite"), description)
        XCTAssertTrue(description.contains("options inside of your muter.conf.yml."), description)
        XCTAssertFalse(description.contains("Muter "), description)
    }

    func test_whenTheLastFiveMutantsDidNotBuild_thenSendPeopleToSwiftMutatorsIssues() {
        let description = MutationTestingAbortReason.tooManyBuildErrors.description

        XCTAssertTrue(description.contains("\nhttps://github.com/Joseph-Cursio/SwiftMutator/issues"), description)
        XCTAssertFalse(description.contains("muter-mutation-testing"), description)
    }

    func test_whenThereIsNoLog_thenSayThereIsNoneRatherThanPrintingAnEmptySection() {
        let description = MutationTestingAbortReason.baselineTestFailed(
            log: "",
            mutatedFilePaths: [mutatedFilePath]
        ).description

        XCTAssertTrue(description.contains("SwiftMutator captured no output at all"), description)
        XCTAssertTrue(description.contains("names a command SwiftMutator can launch"), description)
        XCTAssertFalse(
            description.contains("Here's the log"),
            "Promising a log and then printing nothing leaves the user with no evidence:\n\(description)"
        )
    }

    func test_compilerErrorParsing() {
        let log = """
        Building for debugging...
        /project/Calc.swift:8:24: error: expected expression after operator
        /project/Calc.swift:9:1: warning: unused variable
        /project/Calc.swift:10: error: missing a column
        error: fatalError
        note: /project/Other.swift:1:1: error: quoted inside a note
        """

        XCTAssertEqual(
            CompilerError.all(in: log),
            [
                CompilerError(
                    filePath: "/project/Calc.swift",
                    line: 8,
                    column: 24,
                    message: "expected expression after operator"
                ),
            ]
        )
    }

    // SwiftPM colours what it writes to a log: the parser once found no error at all in one.
    func test_compilerErrorParsing_readsColouredLines() {
        let log = "/project/A.swift:15:19: \u{1B}[1;31merror: \u{1B}[1;39mbinary operator '>'\u{1B}[0;0m\n"

        XCTAssertEqual(
            CompilerError.all(in: log),
            [CompilerError(filePath: "/project/A.swift", line: 15, column: 19, message: "binary operator '>'")]
        )
    }

    // Swift Build's driver has no colon after the column, and comes straight after whatever the progress line printed.
    func test_compilerErrorParsing_readsTheDriversForm() {
        let log = """
        error: /project/A.swift:7:131 #_hasSymbol may only be used as condition
        [28 / 51] Serror: /project/B.swift:1:2 expected: something
        error: SwiftCompile normal arm64 /project/C.swift failed with a nonzero exit code.
        note: error: /project/D.swift:1:2 quoted
        error: relative/E.swift:1:2 not a path SwiftMutator can place
        """

        XCTAssertEqual(CompilerError.all(in: log), [
            CompilerError(
                filePath: "/project/A.swift",
                line: 7,
                column: 131,
                message: "#_hasSymbol may only be used as condition"
            ),
            CompilerError(filePath: "/project/B.swift", line: 1, column: 2, message: "expected: something"),
        ])
    }

    func test_compilerErrorParsing_readsAColonInAPath_andCRLFs() {
        let log = "/Users/a:b/A.swift:1:2: error: first\r\n/Users/a:b/A.swift:3:4: error: second: with a colon\r\n"

        XCTAssertEqual(
            CompilerError.all(in: log),
            [
                CompilerError(filePath: "/Users/a:b/A.swift", line: 1, column: 2, message: "first"),
                CompilerError(filePath: "/Users/a:b/A.swift", line: 3, column: 4, message: "second: with a colon"),
            ]
        )
    }

    // A file of the same name in another target isn't a file SwiftMutator rewrote.
    func test_aFileOfTheSameNameElsewhere_isntBlamedOnTheRewriting() {
        let log = "/project/Other/Calc.swift:1:1: error: its own"

        XCTAssertNil(CompilerError.first(in: log, inFilesAt: [mutatedFilePath]))

        let description = MutationTestingAbortReason.baselineTestFailed(
            log: log,
            mutatedFilePaths: [mutatedFilePath]
        ).description
        XCTAssertTrue(description.contains("misconfiguring"), description)
    }

    // Colours and all, as a real log has it: it may be a project's own error, so that is what's checked first.
    private func baselineFailure(_ log: String, mutatedFilePaths: [String]? = nil) -> String {
        MutationTestingAbortReason.baselineTestFailed(
            log: log,
            mutatedFilePaths: mutatedFilePaths ?? [mutatedFilePath]
        ).description
    }

    // As `swift test` printed it for a real overflow: Swift Testing's thread gets SIGBUS on a Mac, and XCTest's main
    // thread SIGSEGV.
    func test_whenATestProcessDiedOfABadMemoryAccess_thenSayItsLikelyAStackOverflow_andWhatToDo() {
        for signal in [SIGBUS, SIGSEGV] {
            let line = "error: Process '/x/DeepTests --testing-library swift-testing' exited with unexpected "
                + "signal code \(signal)"

            let description = baselineFailure("Test run started.\n\u{1B}[1;31m\(line)\u{1B}[0m\nNote: failures\n")

            XCTAssertTrue(description.contains("a test process crashed, with no mutant switched on"), description)
            XCTAssertTrue(description.contains("  \(line)\n"), description)
            XCTAssertTrue(description.contains("First check that your tests pass in your unmutated"), description)
            XCTAssertTrue(description.contains("the likely reason is a stack overflow"), description)
            XCTAssertTrue(description.contains("Thread stack size exceeded"), description)
            XCTAssertTrue(description.contains("\"exclude\" option"), description)
            XCTAssertTrue(description.contains("// muter:disable"), description)
            XCTAssertFalse(description.contains("misconfiguring"), description)
            XCTAssertTrue(description.contains("Here's the log your test command produced"), description)
        }
    }

    func test_anOlderSwiftPMsSignalLine_isReadToo() {
        XCTAssertTrue(baselineFailure("error: Exited with signal code \(SIGSEGV)\n").contains("likely reason"))
    }

    // Another target's crash can come first in the log.
    func test_aBadMemoryAccessAfterAnotherCrash_isTheOneNamed() {
        let log = "error: Exited with signal code \(SIGABRT)\nerror: Exited with signal code \(SIGBUS)\n"

        XCTAssertTrue(baselineFailure(log).contains("  error: Exited with signal code \(SIGBUS)\n"))
    }

    // xcodebuild gives no signal, and restarts after a timeout as well as a crash.
    func test_whenXcodebuildRestartedAfterACrash_thenSayItMayBeAStackOverflow() {
        let line = "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous"

        let description = baselineFailure("Test Case 'x' started.\n\(line) launches.\n")

        XCTAssertTrue(description.contains("  \(line) launches.\n"), description)
        XCTAssertTrue(description.contains("one possible reason is a stack overflow"), description)
    }

    func test_otherFailures_arentTakenForAStackOverflow() {
        for log in [
            "error: Exited with signal code \(SIGABRT)\n", // a trap, as a failed precondition or fatalError
            "error: Exited with signal code \(SIGILL)\n",
            "error: Exited with signal code 9\n",
            "a test printed: error: Exited with signal code \(SIGBUS)\n",
            "printed Restarting after unexpected exit, crash, or test timeout\n",
            "Test Case 'x' failed (0.1 seconds).\n",
        ] {
            let description = baselineFailure(log)
            XCTAssertFalse(description.contains("stack overflow"), log)
            XCTAssertTrue(description.contains("misconfiguring"), log)
        }
    }

    // Nothing was rewritten, so nothing has grown.
    func test_aCrashWithNoFileRewritten_isntPutDownToTheMutants() {
        let description = baselineFailure("error: Exited with signal code \(SIGBUS)\n", mutatedFilePaths: [])

        XCTAssertFalse(description.contains("stack overflow"), description)
    }

    // A build that failed never ran any test.
    func test_aCompileErrorInARewrittenFile_comesBeforeACrash() {
        let log = "\(mutatedFilePath):8:24: error: expected expression\nerror: Exited with signal code \(SIGBUS)\n"

        let description = baselineFailure(log)

        XCTAssertTrue(description.contains("failed to compile"), description)
        XCTAssertFalse(description.contains("stack overflow"), description)
    }

    func test_whenARewrittenFileFailsToCompile_thenSayToCheckTheProjectFirst() {
        let log = "\(mutatedFilePath):8:24: \u{1B}[1;31merror: \u{1B}[1;39mexpected expression\u{1B}[0;0m\n"

        let description = MutationTestingAbortReason.baselineTestFailed(
            log: log,
            mutatedFilePaths: [mutatedFilePath]
        ).description

        XCTAssertTrue(description.contains("Calc.swift:8:24: error: expected expression"), description)
        XCTAssertTrue(description.contains("First check that Calc.swift compiles"), description)
        XCTAssertTrue(description.contains("bug in SwiftMutator's own rewriting"), description)
    }
}
