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
