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
            didSaveReport: true
        )

        AssertSnapshot(printer.linesPassed.joined(separator: "\n"))
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

        // With two mutants, the first one's log redraws the bar for the last time.
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
            resultsFile: "/logs/results.jsonl"
        )
        sut.mutationTestingEndedEarly(
            .make(reason: .aborted, detail: "tooManyBuildErrors", tested: [.failed, .buildError], discovered: 9),
            partialReport: nil,
            resultsFile: nil
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

        sut.mutationTestingEndedEarly(.make(tested: [.failed]), partialReport: nil, resultsFile: resultsFile)

        let quoted = #"'/logs/Bob'\''s project_muter_logs/Oct 4, 2026 at 1:16 PM/results.jsonl'"#
        XCTAssertEqual(standardError.linesPassed.last, "📝 Full report: swift-mutator report \(quoted)")
        XCTAssertEqual(try wordsAShellReads(in: quoted), [resultsFile])
    }

    // There is no score to give, and no report: a report needs a tested mutant.
    func test_mutationTestingEndedEarly_withNothingTested_leavesTheScoreOut() {
        sut.mutationTestingEndedEarly(
            .make(reason: .interrupted, detail: "SIGINT", tested: [], discovered: 9),
            partialReport: nil,
            resultsFile: "/logs/results.jsonl"
        )

        XCTAssertEqual(standardError.linesPassed, [
            "⏹ Stopped by SIGINT before any of 9 mutants finished.",
            "💾 Each tested mutant's result is in \("/logs/results.jsonl".bold)",
        ])
    }

    func test_mutationTestingEndedEarly_whenThePartialReportCouldNotBeSaved_saysWhere() {
        sut.mutationTestingEndedEarly(
            .make(tested: [.failed]),
            partialReport: (path: "/out/report.partial.txt", saved: false),
            resultsFile: nil
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

    /// The words `/bin/sh` reads in `text`, as it would reading a command whose arguments are `text`.
    private func wordsAShellReads(in text: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"printf '%s\0' "# + text]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
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
}
