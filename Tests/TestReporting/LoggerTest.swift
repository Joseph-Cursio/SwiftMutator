import Foundation
@testable import muterCore
import Rainbow
import TestingExtensions

final class LoggerTests: MuterTestCase {
    private let sut = Logger()

    func test_printer() throws {
        sut.launched()
        sut.updateCheckStarted()
        sut.updateCheckFinished(newVersion: "1.0.0")
        sut.projectCopyStarted()
        sut.projectCopyFinished(destinationPath: "/path/to/destination")
        sut.projectCoverageDiscoveryStarted()
        sut.projectCoverageDiscoveryFinished(success: true)
        sut.sourceFileDiscoveryStarted()
        sut.sourceFileDiscoveryFinished(sourceFileCandidates: ["file0.swift", "file1.swift", "file2.swift"])
        sut.mutationsDiscoveryStarted()
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping()])
        sut.mutationTestingStarted()
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(
                timePerBuildTestCycle: 50,
                remainingMutationPointsCount: 5
            )
        )
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(
                mutationPoint: .make()
            )
        )
        sut.testPlanFileCreated(atPath: "/path/to/test-plan")
        sut.configurationFileCreated(atPath: "/path/to/config-file")
        sut.muterMutationTestPlanLoaded()
        sut.mutationTestingFinished(
            report: "... muter report ... ",
            reportPath: "/path/to/report",
            isExportingReport: true,
            didSaveReport: true,
            suspectWarning: nil
        )

        AssertSnapshot(printer.linesPassed.joined(separator: "\n"))
    }

    // Last, after where the report went or the report itself, whether or not it was saved: the line a run ends on.
    func test_mutationTestingFinished_withASuspectWarning_printsItLast() {
        let warning = "1 test may fail whatever the mutant: it failed for mutants in at least 15% of the 10 files "
            + "with a killed mutant (timing() in 10). Without its failures, the mutation score would be 0%, not 90%."

        sut.mutationTestingFinished(
            report: "the report",
            reportPath: "/out/report.txt",
            isExportingReport: true,
            didSaveReport: true,
            suspectWarning: warning
        )
        sut.mutationTestingFinished(
            report: "the report",
            reportPath: "",
            isExportingReport: false,
            didSaveReport: false,
            suspectWarning: warning
        )
        sut.mutationTestingFinished(
            report: "the report",
            reportPath: "/out/report.txt",
            isExportingReport: true,
            didSaveReport: false,
            suspectWarning: warning
        )

        XCTAssertEqual(printer.linesPassed, [
            "🏁 SwiftMutator finished running!",
            "📝 Report generated: \("/out/report.txt".bold)",
            "⚠️ \(warning)",
            "🏁 SwiftMutator finished running!",
            "📝 SwiftMutator's report\n\nthe report",
            "⚠️ \(warning)",
            "🏁 SwiftMutator finished running!",
            "the report",
            "\n",
            "Could not save report!",
            "⚠️ \(warning)",
        ])
        XCTAssertEqual(standardError.linesPassed, [])
    }

    // Each worker tests its share of the mutants while the others test theirs, so the time left is the longest
    // share's: 3 of 5 mutants for one of 2 workers.
    func test_theFirstEstimate_spreadsTheMutantsOverTheWorkers() {
        XCTAssertEqual(Logger.initialEstimate(remaining: 5, cycle: 50, workers: 2), 150)
        XCTAssertEqual(Logger.initialEstimate(remaining: 5, cycle: 50, workers: 1), 250)
    }

    func test_print_writesThroughTheInjectedPrinter() {
        sut.print("a line")

        XCTAssertEqual(printer.linesPassed, ["a line"])
    }

    func test_projectCopySkippedVanishedFiles_listsUpToFivePaths() {
        sut.projectCopySkippedVanishedFiles((1 ... 7).map { "/p/f\($0).lock" })

        XCTAssertEqual(printer.linesPassed, [
            """
            ⚠️ Skipped 7 file(s) that disappeared while your project was being copied:
              /p/f1.lock
              /p/f2.lock
              /p/f3.lock
              /p/f4.lock
              /p/f5.lock
              … and 2 more
            """,
        ])
    }

    func test_resultsFileUnavailable_saysTheReportDoesntDependOnIt() {
        sut.resultsFileUnavailable(reason: "can't open /logs/results.jsonl: Permission denied")

        XCTAssertEqual(printer.linesPassed, [
            "⚠️ SwiftMutator can't save each mutant's result as it goes: "
                + "can't open /logs/results.jsonl: Permission denied. The report at the end doesn't depend on it.",
        ])
    }

    // A burst of finished mutants redraws the bar once: it's drawn at most every tenth of a second, by the injected
    // clock, so the time between draws can be tested.
    func test_theProgressBar_isRedrawnAtMostEveryTenthOfASecond() throws {
        var nanoseconds: UInt64 = 1
        current.instant = { DispatchTime(uptimeNanoseconds: nanoseconds) }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 5).map { _ in try makeSchemataMapping() })
        var draws: [Int] = []
        func drawn() -> Int { printer.linesPassed.filter { $0.contains("Percentage complete:") }.count }

        sut.newMutationTestLogAvailable(mutationTestLog: .make(timePerBuildTestCycle: 60, remainingMutationPointsCount: 5))
        draws.append(drawn())
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        draws.append(drawn())
        nanoseconds += 150_000_000
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        draws.append(drawn())

        XCTAssertEqual(draws, [1, 1, 2])
    }

    // The bar is drawn once the baseline passes, with no mutant tested yet, and again as each mutant finishes, so it
    // reaches 100% with the last one. It counted from 1, which put it one mutant ahead, never drew the last mutant,
    // and never showed the first estimate, which only a bar at 0 shows.
    func test_theProgressBar_countsTheMutantsTested_fromNoneToAll() throws {
        var nanoseconds: UInt64 = 1
        current.instant = {
            nanoseconds += 200_000_000
            return DispatchTime(uptimeNanoseconds: nanoseconds)
        }
        try sut.mutationsDiscoveryFinished(mutations: (0 ..< 3).map { _ in try makeSchemataMapping() })

        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 600, remainingMutationPointsCount: 3)
        )
        for _ in 0 ..< 3 {
            sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        }

        let draws = printer.linesPassed.filter { $0.contains("Percentage complete:") }
        XCTAssertEqual(draws.map(percent), ["0%", "33%", "66%", "100%"])
        // Three mutants, 600 s each, on one worker.
        XCTAssertTrue(draws.first?.contains("ETC: 30 ") == true, draws.first ?? "no draw")
    }

    // The progress bar's printer redraws it by moving the cursor up over its two lines, which would overwrite the
    // warning's last two rows. The empty lines take the redraw instead. After the bar's last redraw they aren't needed.
    func test_resultsFileUnavailable_whileTheProgressBarIsStillToRedraw_leavesItTwoEmptyLines() throws {
        let reason = "can't write to /logs/results.jsonl: No space left on device"
        let warning = "⚠️ SwiftMutator can't save each mutant's result as it goes: "
            + "\(reason). The report at the end doesn't depend on it."
        try sut.mutationsDiscoveryFinished(mutations: [makeSchemataMapping(), makeSchemataMapping()])
        sut.newMutationTestLogAvailable(
            mutationTestLog: .make(timePerBuildTestCycle: 50, remainingMutationPointsCount: 2)
        )

        var printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning, "", ""])

        // With one mutant left, the bar still has its last redraw to come.
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning, "", ""])

        // The second mutant's log redraws the bar for the last time.
        sut.newMutationTestLogAvailable(mutationTestLog: .make(mutationPoint: .make()))
        printedBefore = printer.linesPassed.count
        sut.resultsFileUnavailable(reason: reason)
        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [warning])
    }

    func test_resultsFileCreated_andKept_nameTheFile() {
        sut.resultsFileCreated(atPath: "/logs/results.jsonl")
        sut.resultsFileKept(atPath: "/logs/results.jsonl")

        XCTAssertEqual(printer.linesPassed, [
            "💾 SwiftMutator saves each mutant's result as it finishes, in \("/logs/results.jsonl".bold)",
            "💾 Each mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    // The progress bar counts the mutants left to test, not every one discovery found. Each reason a mutant is tested
    // again is counted, in the plan's order, and only when it has any.
    func test_resumePlanned_saysWhatIsReusedAndRetested_andSetsTheProgressTotal() throws {
        try sut.mutationsDiscoveryFinished(mutations: Array(repeating: makeSchemataMapping(), count: 4))
        let printedBefore = printer.linesPassed.count

        sut.resumePlanned(.make(reused: 1103, toTest: 1394, retestedBecause: [.buildError: 5, .notRecorded: 1389]))

        XCTAssertEqual(sut.numberOfMutationPoints, 1394)
        sut.resumePlanned(
            .make(
                reused: 1,
                toTest: 7,
                retestedBecause: [.repeated: 2, .mutationChanged: 1, .fileChanged: 3, .buildError: 1, .notRecorded: 0]
            )
        )
        sut.resumePlanned(.make(reused: 0, toTest: 1, retestedBecause: [.fileChanged: 1]))

        XCTAssertEqual(Array(printer.linesPassed.dropFirst(printedBefore)), [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1103 results still hold, "
                + "so 1394 mutants are left to test (1389 never tested, 5 build errors).",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 1 result still holds, so 7 mutants are left to test "
                + "(1 build error, 3 in changed files, 1 changed mutation, 2 repeated in their file).",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 0 results still hold, "
                + "so 1 mutant is left to test (1 in a changed file).",
        ])
        XCTAssertEqual(sut.numberOfMutationPoints, 1)
    }

    func test_resumePlanned_withNothingLeft_saysSo() {
        sut.resumePlanned(.make(reused: 2497, toTest: 0, retestedBecause: [:]))
        sut.resumePlanned(.make(reused: 1, toTest: 0, retestedBecause: [:]))

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): all 2497 results still hold, "
                + "so nothing is left to test.",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): its only result still holds, "
                + "so nothing is left to test.",
        ])
        XCTAssertEqual(sut.numberOfMutationPoints, 0)
    }

    // A change no result depends on is only said. What --force-resume and --resume-ignoring let through is a warning:
    // the results are reused on the user's word.
    func test_resumePlanned_namesForcedWaivedAndNotices() {
        sut.resumePlanned(
            .make(
                forced: ["swiftMutator.executableSHA256", "toolchain.testCommandVersion"],
                waived: ["README.md", "notes.txt"],
                notices: ["mutationTestWorkers was 4 and is 2 now, which no result depends on."]
            )
        )
        sut.resumePlanned(
            .make(
                forced: ["toolchain.environment"],
                waived: (1...12).map { "Docs/rules/rule\($0).md" }
            )
        )

        XCTAssertEqual(printer.linesPassed, [
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 2 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "ℹ️ mutationTestWorkers was 4 and is 2 now, which no result depends on.",
            "⚠️ Results are reused although SwiftMutator and the toolchain changed (--force-resume).",
            "⚠️ Results are reused although 2 project files changed (--resume-ignoring): README.md, notes.txt",
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 2 results still hold, "
                + "so 2 mutants are left to test (2 never tested).",
            "⚠️ Results are reused although the toolchain's environment changed (--force-resume).",
            "⚠️ Results are reused although 12 project files changed (--resume-ignoring): "
                + (1...10).map { "Docs/rules/rule\($0).md" }.joined(separator: ", ") + ", and 2 more",
        ])
    }

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
            partialReport: (path: "/out/report.partial.txt", saved: true),
            resultsFile: "/logs/results.jsonl",
            continueCommand: nil
        )
        sut.mutationTestingEndedEarly(
            .make(reason: .aborted, detail: "tooManyBuildErrors", tested: [.failed, .buildError], discovered: 9),
            partialReport: nil,
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

    // Log folders are named like `Oct 4, 2026 at 1:16 PM`, and a project's name can hold a quote: the command is printed
    // so that it pastes into a shell whatever the path holds, and unbolded, so that no colour codes paste with it.
    func test_mutationTestingEndedEarly_namesTheReportCommand_quotingItsPath() throws {
        let resultsFile = "/logs/Bob's project_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl"

        sut.mutationTestingEndedEarly(
            .make(tested: [.failed]),
            partialReport: nil,
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
            partialReport: (path: "/out/report.partial.txt", saved: true),
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
            partialReport: nil,
            resultsFile: "/logs/results.jsonl",
            continueCommand: continueCommand
        )
        sut.mutationTestingEndedEarly(
            .make(detail: "SIGTERM", tested: [.failed, .passed, .passed], discovered: 9, reused: 3),
            partialReport: nil,
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
            partialReport: nil,
            resultsFile: nil,
            continueCommand: continueCommand
        )
        sut.mutationTestingEndedEarly(
            .make(detail: "SIGINT", tested: [], discovered: 4),
            partialReport: nil,
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
            partialReport: nil,
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
            partialReport: (path: "/out/report.partial.txt", saved: true),
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
            partialReport: (path: "/out/report.partial.txt", saved: false),
            resultsFile: nil,
            continueCommand: nil
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by a signal after testing 1 of 4 mutants. Mutation score so far: 100%.",
            "⚠️ Could not save the partial report to /out/report.partial.txt",
        ])
    }

    private func makeSchemataMapping() throws -> SchemataMutationMapping {
        try SchemataMutationMapping.make(
            filePath: "/some/path",
            (
                source: "func bar() { }",
                schemata: [
                    .make(
                        filePath: "/tmp/project/file.swift",
                        mutationOperatorId: .ror,
                        syntaxMutation: "",
                        position: .firstPosition,
                        snapshot: .null
                    ),
                ]
            )
        )
    }

    func test_mutationsDiscoveryFinished_countsFilesWithTheSameNameTogether() throws {
        let mappings = try ["/project/First/main.swift", "/project/Second/main.swift"].map { path in
            try SchemataMutationMapping.make(
                filePath: path,
                (source: "func bar() { }", schemata: [.make(filePath: path, position: .firstPosition)])
            )
        }

        sut.mutationsDiscoveryFinished(mutations: mappings)

        XCTAssertTrue(
            printer.linesPassed.contains("main.swift (2 mutants)".bold),
            "\(printer.linesPassed)"
        )
    }

    /// The percentage a drawn progress bar shows.
    private func percent(_ draw: String) -> String {
        guard let sign = draw.range(of: "%") else { return "" }
        return String(draw[..<sign.lowerBound].reversed().prefix(while: \.isNumber).reversed()) + "%"
    }
}
