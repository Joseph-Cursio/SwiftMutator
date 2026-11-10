import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

extension LoggerTests {
    func test_stopAtFirstFailureTurnedOff_saysWhy() {
        sut.stopAtFirstFailureTurnedOff(reason: "the test arguments retry failing tests")

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ stopAtFirstFailure is off for this run, so every mutant's tests run to the end: "
                + "the test arguments retry failing tests",
        ])
    }

    // On standard error: a `| tee` that the same Ctrl-C ended has closed standard output.
    func test_mutationTestingEndedEarly_saysWhatStoppedIt_andTheScoreSoFar() {
        sut.mutationTestingEndedEarly(
            .make(reason: .interrupted, detail: "SIGTERM", tested: [.failed, .passed, .buildError], discovered: 9),
            partialReports: [(path: "/out/report.partial.txt", saved: true)],
            resultsFile: "/logs/results.jsonl",
            continueCommand: nil
        )
        sut.mutationTestingEndedEarly(
            .make(reason: .aborted, detail: "tooManyBuildErrors", tested: [.failed, .buildError], discovered: 9),
            partialReports: [],
            resultsFile: nil,
            continueCommand: nil
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGTERM after testing 3 of 9 mutants. Mutation score so far: 50%.",
            "📝 Partial report: \("/out/report.partial.txt".bold)",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            // The error banner follows on standard output.
            "⏹ Stopped by the error below after testing 2 of 9 mutants. Mutation score so far: 100%.",
        ])
        XCTAssertEqual(printer.linesPassed, [])
    }

    // Log folders are named like `Oct 4, 2026 at 1:16 PM`, and a project's name can hold a quote: the command is
    // printed so that it pastes into a shell whatever the path holds, and unbolded, so that no colour codes paste with
    // it.
    func test_mutationTestingEndedEarly_namesTheReportCommand_quotingItsPath() throws {
        let resultsFile = "/logs/Bob's project_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl"

        sut.mutationTestingEndedEarly(
            .make(tested: [.failed]),
            partialReports: [],
            resultsFile: resultsFile,
            continueCommand: nil
        )

        let quoted = #"'/logs/Bob'\''s project_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl'"#
        XCTAssertEqual(standardError.linesPassed.last, "📝 Full report: swift-mutator report \(quoted)")
        XCTAssertEqual(try wordsAShellReads(in: quoted), [resultsFile])
    }

    // Last, after the command that reports what was tested, and unbolded, so that no colour codes paste with it.
    func test_mutationTestingEndedEarly_namesTheCommandThatContinues() {
        let continueCommand = "swift-mutator run -o report.txt --resume '/logs/results.jsonl'"

        sut.mutationTestingEndedEarly(
            .make(reason: .interrupted, detail: "SIGINT", tested: [.failed, .passed], discovered: 4),
            partialReports: [(path: "/out/report.partial.txt", saved: true)],
            resultsFile: "/logs/results.jsonl",
            continueCommand: continueCommand
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 2 of 4 mutants. Mutation score so far: 50%.",
            "📝 Partial report: \("/out/report.partial.txt".bold)",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "▶️ Continue: swift-mutator run -o report.txt --resume '/logs/results.jsonl'",
        ])
        XCTAssertEqual(printer.linesPassed, [])
    }

    // A resumed session tests only the mutants left. It says how many of them it tested, and how many of every mutant
    // have a result, kept or tested; the score is over them all, as the report's is. Kept results alone still make a
    // report, and a run to continue.
    func test_ofAResumedSession_countsReusedApart() {
        let continueCommand = "swift-mutator run --resume '/logs/results.jsonl'"

        sut.mutationTestingEndedEarly(
            .make(detail: "SIGINT", tested: [.failed, .failed, .passed, .failed, .passed], discovered: 9, reused: 3),
            partialReports: [],
            resultsFile: "/logs/results.jsonl",
            continueCommand: continueCommand
        )
        sut.mutationTestingEndedEarly(
            .make(detail: "SIGTERM", tested: [.failed, .passed, .passed], discovered: 9, reused: 3),
            partialReports: [],
            resultsFile: "/logs/results.jsonl",
            continueCommand: continueCommand
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 2 of the 6 mutants left: 5 of 9 have results. "
                + "Mutation score so far: 60%.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "▶️ Continue: swift-mutator run --resume '/logs/results.jsonl'",
            "⏹ Stopped by SIGTERM before any of the 6 mutants left finished: 3 of 9 have results. "
                + "Mutation score so far: 33%.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "▶️ Continue: swift-mutator run --resume '/logs/results.jsonl'",
        ])
    }

    // Without a results file there is nothing to resume from. Without a result, a resume would keep nothing that a new
    // run doesn't.
    func test_noContinueLine_withoutAResultsFileOrAnyResult() {
        let continueCommand = "swift-mutator run --resume '/logs/results.jsonl'"

        sut.mutationTestingEndedEarly(
            .make(detail: "SIGINT", tested: [.failed], discovered: 4),
            partialReports: [],
            resultsFile: nil,
            continueCommand: continueCommand
        )
        sut.mutationTestingEndedEarly(
            .make(detail: "SIGINT", tested: [], discovered: 4),
            partialReports: [],
            resultsFile: "/logs/results.jsonl",
            continueCommand: continueCommand
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 1 of 4 mutants. Mutation score so far: 100%.",
            "⏹ Stopped by SIGINT before any of 4 mutants finished.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    // There is no score to give, and no report: a report needs a tested mutant.
    func test_mutationTestingEndedEarly_withNothingTested_leavesTheScoreOut() {
        sut.mutationTestingEndedEarly(
            .make(reason: .interrupted, detail: "SIGINT", tested: [], discovered: 9),
            partialReports: [],
            resultsFile: "/logs/results.jsonl",
            continueCommand: nil
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT before any of 9 mutants finished.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    // Straight after the score so far, which it qualifies, and on standard error with it. Its score is that one's: the
    // kills only suspect tests were recorded failing for, of the mutants tested so far.
    func test_mutationTestingEndedEarly_withSuspects_warnsAfterTheStoppedLine() {
        let earlyEnd = EarlyEnd(
            reason: .interrupted,
            detail: "SIGINT",
            outcome: .withSuspectTests,
            discovered: 20,
            reused: 0
        )

        sut.mutationTestingEndedEarly(
            earlyEnd,
            partialReports: [(path: "/out/report.partial.txt", saved: true)],
            resultsFile: "/logs/results.jsonl",
            continueCommand: "swift-mutator run --resume '/logs/results.jsonl'"
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT after testing 14 of 20 mutants. Mutation score so far: 92%.",
            "⚠️ 2 tests may fail whatever the mutant: they failed for mutants in at least 15% of the 12 files with a "
                + "killed mutant (timing() in 12, order() in 10). Without their failures, the mutation score would be "
                + "at least 50%, not 92%.",
            "📝 Partial report: \("/out/report.partial.txt".bold)",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
            "📝 Full report: swift-mutator report '/logs/results.jsonl'",
            "▶️ Continue: swift-mutator run --resume '/logs/results.jsonl'",
        ])
        XCTAssertEqual(printer.linesPassed, [])
    }

    func test_mutationTestingEndedEarly_whenThePartialReportCouldNotBeSaved_saysWhere() {
        sut.mutationTestingEndedEarly(
            .make(tested: [.failed]),
            partialReports: [(path: "/out/report.partial.txt", saved: false)],
            resultsFile: nil,
            continueCommand: nil
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by a signal after testing 1 of 4 mutants. Mutation score so far: 100%.",
            "⚠️ Could not save the partial report to /out/report.partial.txt",
        ])
    }
}
