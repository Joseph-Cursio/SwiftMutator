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
