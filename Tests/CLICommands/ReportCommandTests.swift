import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// `swift-mutator report`: parsed as the command line gives it, then run on results files in a temporary folder.
final class ReportCommandTests: MuterTestCase {
    private var directory = ""
    private var resultsPath: String { "\(directory)/results.jsonl" }

    /// Discovery puts Alpha.swift first, and Zeta.swift's line 9 before its line 10, though as text, as in a switch ID,
    /// 10 comes first; the run wrote them in the order they finished in.
    private let zeta9 = MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed)
    private let alpha3 = MutantResult.make(path: "Sources/Alpha.swift", line: 3, outcome: .failed)
    private let zeta10 = MutantResult.make(path: "Sources/Zeta.swift", line: 10, outcome: .passed)

    /// The outcome the run reported: `ResultsHeader.make()` records a run that skipped coverage.
    private var expected: MutationTestOutcome {
        expected(from: [resultsPath])
    }

    /// `outcome`, of the results files at `paths`, `resultsPath` alone by default, each file's last header `header`.
    private func ran(
        _ outcome: MutationTestOutcome,
        from paths: [String]? = nil,
        header: ResultsHeader = .make()
    ) -> MutationTestOutcome {
        var outcome = outcome
        outcome.run = RunDetails(of: (paths ?? [resultsPath]).map { ($0, [header]) })
        return outcome
    }

    /// The outcome the run reported, of the results files at `paths`, each of whose last header is `header`.
    private func expected(from paths: [String], header: ResultsHeader = .make()) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: [
                mutation("Sources/Alpha.swift", line: 3, .failed),
                mutation("Sources/Zeta.swift", line: 9, .passed),
                mutation("Sources/Zeta.swift", line: 10, .passed),
            ],
            coverage: .null,
            coverageSkipped: true,
            testDuration: 100.5,
            newVersion: "",
            projectPath: header.projectPath,
            mutatedProjectPath: header.mutatedProjectPath,
            run: RunDetails(of: paths.map { ($0, [header]) })
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try makeTemporaryDirectory()
    }

    // After setUpWithError, which XCTest calls first: MuterTestCase installs the spies in both.
    override func setUp() {
        super.setUp()

        // Real files: the spy's createFile always succeeds, and its contentsOfDirectory can't tell a folder from a
        // file.
        current.fileManager = FileManager.default
    }

    func test_parsesAsTheReportSubcommand() throws {
        fileManager.currentDirectoryPathToReturn = "/project"
        current.fileManager = fileManager

        let command = try MuterCommand.parseAsRoot(["report", "r.jsonl", "-f", "json", "-o", "/out/r.json"])

        let report = try XCTUnwrap(command as? Report)
        XCTAssertEqual(report.results.map(\.path), ["/project/r.jsonl"])
        XCTAssertEqual(report.reportOptions.reportFormat, .json)
        XCTAssertEqual(report.reportOptions.reportURL?.path, "/out/r.json")
    }

    func test_runIsStillTheDefaultSubcommand() throws {
        XCTAssertTrue(try MuterCommand.parseAsRoot(["--skip-coverage"]) is Run)
    }

    func test_needsAResultsPath() {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["report"]))
    }

    func test_showsTheLabelsInTheRunsProject() async throws {
        try write(ResultsHeader.make(projectPath: directory), zeta9, ResultsEnd.make(), to: resultsPath)
        try writeTriage(to: "\(directory)/\(TriageFile.fileName)", label: "equivalent")

        try await report(resultsPath)

        XCTAssertTrue(printer.linesPassed.first?.contains("Triaged: equivalent") == true, "\(printer.linesPassed)")
    }

    func test_showsTheLabelsInTheCurrentFolder_whenTheRunsProjectHasNone() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        try writeTriage(to: "\(directory)/\(TriageFile.fileName)", label: "missing-test")
        let before = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(directory)
        defer { FileManager.default.changeCurrentDirectoryPath(before) }

        try await report(resultsPath)

        XCTAssertTrue(printer.linesPassed.first?.contains("Triaged: missing test") == true, "\(printer.linesPassed)")
    }

    func test_triageFlag_namesTheFile_whichMustBeThere() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        let file = "\(directory)/labels.yml"

        await XCTAssertThrowsErrorAsync(try await report(resultsPath, "--triage", file))

        try writeTriage(to: file, label: "tool-limitation")
        try await report(resultsPath, "--triage", file)
        XCTAssertTrue(printer.linesPassed.first?.contains("Triaged: tool limitation") == true, "\(printer.linesPassed)")
    }

    func test_aBrokenTriageFile_isRefused() async throws {
        try write(ResultsHeader.make(projectPath: directory), zeta9, ResultsEnd.make(), to: resultsPath)
        try "mutants: [".write(toFile: "\(directory)/\(TriageFile.fileName)", atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await report(resultsPath))
        XCTAssertEqual(printer.linesPassed, [])
    }

    func test_printsTheReportOnStandardOutput_andTheStatusOnStandardError() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath)

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(resultsPath): the run finished."]
        )
    }

    func test_savesTheReportToTheOutputPath_replacingAnOldOne() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/report.json"
        try "an older, longer report than this one".write(toFile: output, atomically: true, encoding: .utf8)

        try await report(resultsPath, "-f", "json", "-o", output)

        XCTAssertEqual(
            try parsedJSON(String(contentsOfFile: output, encoding: .utf8)),
            try parsedJSON(JsonReporter().report(from: expected))
        )
        XCTAssertEqual(printer.linesPassed, [])
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 3 of 3 mutants, from \(resultsPath): the run finished.",
                "Mutation score: 33% (1 killed, 2 survived)",
                "Report saved to \(output)",
            ]
        )
    }

    func test_acceptsARunsLogFolder() async throws {
        let folder = "\(directory)/project_muter_logs/Oct 4, 2026 at 1:16 PM"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "a mutant's test log".write(
            toFile: "\(folder)/RelationalOperatorReplacement @ Sum.swift-73-22.log", atomically: true, encoding: .utf8
        )
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: "\(folder)/results.jsonl")

        try await report(folder)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: ["\(folder)/results.jsonl"]))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(folder)/results.jsonl: the run finished."]
        )
    }

    // A resumed session's folder holds no results file but a note naming the one it adds to, in the first session's.
    func test_acceptsAResumedSessionsLogFolder() async throws {
        let (first, resumed) = try makeAResumedRunsLogFolders()

        try await report(resumed)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: ["\(first)/results.jsonl"]))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(first)/results.jsonl: the run finished."]
        )
    }

    func test_aResumedRunsFile_saysWhichSessionsTestedItsResults() async throws {
        let resumed = ResultsHeader.make(
            formatVersion: ResultsCoding.resumedFormatVersion, session: 2, mutantsReused: 1
        )
        let alpha3Again = MutantResult.make(session: 2, path: "Sources/Alpha.swift", line: 3, outcome: .failed)
        let zeta10Resumed = MutantResult.make(session: 2, path: "Sources/Zeta.swift", line: 10, outcome: .passed)
        try write(
            ResultsHeader.make(),
            zeta9,
            alpha3,
            // The sessions' test durations add up to the 100.5 seconds `expected` has.
            ResultsEnd.make(reason: .interrupted, detail: "SIGINT", testDurationSeconds: 40),
            resumed,
            ResultsRetired(session: 2, keys: [alpha3.key]),
            alpha3Again,
            zeta10Resumed,
            ResultsEnd.make(session: 2, testDurationSeconds: 60.5),
            to: resultsPath
        )

        try await report(resultsPath)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: [resultsPath], header: resumed))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 3 of 3 mutants, from \(resultsPath): the run finished.",
                "Of these, 2 were tested in the last session, session 2, and 1 in session 1.",
            ]
        )
    }

    // As a glob over the run's log folders gives them, in any order: one file, reported as it is, not merged.
    func test_aRunsFirstAndResumedFolders_reportItsFileOnce() async throws {
        let (first, resumed) = try makeAResumedRunsLogFolders()
        let second = "\(directory)/project_muter_logs/session 3"
        try FileManager.default.createDirectory(atPath: second, withIntermediateDirectories: true)
        try writeNote(pointingTo: "\(first)/results.jsonl", session: 3, in: second)

        for folders in [[first, resumed], [resumed, first], [resumed, second], [second, first, resumed]] {
            let printed = printer.linesPassed.count
            let said = standardError.linesPassed.count

            try await report(folders)

            XCTAssertEqual(
                Array(printer.linesPassed.dropFirst(printed)),
                [PlainTextReporter().report(from: expected(from: ["\(first)/results.jsonl"]))],
                "\(folders)"
            )
            XCTAssertEqual(
                Array(standardError.linesPassed.dropFirst(said)),
                ["Report of 3 of 3 mutants, from \(first)/results.jsonl: the run finished."],
                "\(folders)"
            )
        }
    }

    // The note spells the file's path as the resume was given it, here through a symbolic link to the logs, and the
    // glob spells it another way.
    func test_aRunsFirstAndResumedFolders_reportItsFileOnce_howeverTheNoteSpellsItsPath() async throws {
        let (first, resumed) = try makeAResumedRunsLogFolders()
        let linked = "\(directory)/linked logs"
        try FileManager.default.createSymbolicLink(
            atPath: linked,
            withDestinationPath: "\(directory)/project_muter_logs"
        )
        try writeNote(pointingTo: "\(linked)/session 1/results.jsonl", session: 2, in: resumed)

        try await report(first, resumed)

        XCTAssertEqual(
            printer.linesPassed,
            [PlainTextReporter().report(from: expected(from: ["\(first)/results.jsonl"]))]
        )
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(first)/results.jsonl: the run finished."]
        )
    }

    // Only a file a note names is dropped as a repeat: a shard's file given twice by its own path or folder is still
    // refused, as a mistake in the command.
    func test_aShardsFileGivenTwice_isStillRefused() async throws {
        let (first, resumed) = try makeAResumedRunsLogFolders(header: shardHeader(1, mutantsDiscovered: 2))

        await assertRefused(
            try await report(first, first, resumed),
            MergeRefused(reasons: [
                .givenTwice(Shard(index: 1, count: 2), paths: ["\(first)/results.jsonl", "\(first)/results.jsonl"]),
            ])
        )
    }

    // As in a run, each surviving mutant's warning is printed whether or not the report is saved to a file.
    func test_theXcodeFormat_warnsOfEachSurvivor_inJobOrder_thenGivesItsSummary() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let warnings = [
            "/project/Sources/Zeta.swift:9:22: warning: Your test suite did not kill this mutant: changed > to <",
            "/project/Sources/Zeta.swift:10:22: warning: Your test suite did not kill this mutant: changed > to <",
        ]
        let summary = """
        Mutation score: 33
        Mutants introduced into your code: 3
        Number of killed mutants: 1
        Mutants by outcome: 1 killed, 2 survived
        """

        try await report(resultsPath, "-f", "xcode")

        XCTAssertEqual(printer.linesPassed, warnings + [summary])

        let output = "\(directory)/report.txt"
        try await report(resultsPath, "-f", "xcode", "-o", output)

        XCTAssertEqual(printer.linesPassed, warnings + [summary] + warnings)
        XCTAssertEqual(try String(contentsOfFile: output, encoding: .utf8), summary)
    }

    func test_aFileThatIsNotAResultsFile_isRefused_withExitStatus1() async throws {
        let notResults = "\(directory)/notes.txt"
        try "some notes\n".write(toFile: notResults, atomically: true, encoding: .utf8)
        let output = "\(directory)/report.txt"

        await assertRefused(
            try await report(notResults, "-o", output),
            ResultsFileError.notAResultsFile(path: notResults),
            saying: "Error: \(notResults) isn't a SwiftMutator results file: it has no header line"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    func test_aMissingFile_isRefused() async {
        let missing = "\(directory)/missing.jsonl"

        await assertRefused(
            try await report(missing),
            ResultsFileError.unreadable(path: missing),
            saying: "Error: can't read \(missing)"
        )
    }

    func test_aFolderWithSeveralResultsFiles_isRefused() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: "\(directory)/results.jsonl")
        try write(ResultsHeader.make(), alpha3, ResultsEnd.make(), to: "\(directory)/results-2.jsonl")

        await assertRefused(
            try await report(directory),
            ResultsFileError.severalResultsFiles(folder: directory, names: ["results.jsonl", "results-2.jsonl"])
        )
    }

    func test_whenTheReportCannotBeSaved_itFails() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/missing/report.txt"

        await assertRefused(
            try await report(resultsPath, "-o", output),
            MuterError.literal(reason: "SwiftMutator could not save the report to \(output)"),
            saying: "Error: SwiftMutator could not save the report to \(output)"
        )
    }

    // Saving a report replaces whatever is at its path, so a report saved over its own results file would destroy it.
    func test_neverWritesOverTheResultsFileItReads() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let contents = try Data(contentsOf: URL(fileURLWithPath: resultsPath))
        let (linkedFolder, link) = try makeDirectoryWithSymbolicLink()
        try FileManager.default.copyItem(atPath: resultsPath, toPath: "\(linkedFolder)/results.jsonl")
        // Another name for the same file, as a different case gives on a case-insensitive volume.
        try FileManager.default.linkItem(atPath: resultsPath, toPath: "\(directory)/hard link.jsonl")

        for (results, output) in [
            (resultsPath, resultsPath),
            (resultsPath, "\(directory)/./results.jsonl"),
            (directory, resultsPath),
            ("\(linkedFolder)/results.jsonl", "\(link)/results.jsonl"),
            (resultsPath, "\(directory)/hard link.jsonl"),
        ] {
            await assertRefused(
                try await report(results, "-o", output),
                MuterError.literal(
                    reason: "\(output) is the results file the report is made from: choose another output path"
                ),
                output
            )
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: resultsPath)), contents)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(linkedFolder)/results.jsonl")), contents)
    }

    // Saving a report replaces whatever is at its path, and a folder would go with everything in it.
    func test_neverReplacesAFolder() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let reports = "\(directory)/reports"
        try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
        try "last week's report".write(toFile: "\(reports)/old.txt", atomically: true, encoding: .utf8)

        await assertRefused(
            try await report(resultsPath, "-o", reports),
            MuterError.literal(reason: "\(reports) is a folder: name the file to save the report to"),
            saying: "Error: \(reports) is a folder: name the file to save the report to"
        )
        XCTAssertEqual(try String(contentsOfFile: "\(reports)/old.txt", encoding: .utf8), "last week's report")
    }

    // A script that checks the report fails as one that checked the run would: the run exited 4 for its abort. The
    // report and the status are still given first, and ArgumentParser prints nothing more.
    func test_aRunThatStoppedOnAnError_isReported_thenExitsAsTheRunDid() async throws {
        let end = ResultsEnd.make(reason: .aborted, detail: "mutantNotSwitchedOn")
        try write(ResultsHeader.make(), alpha3, end, to: resultsPath)

        await AssertThrowsError(try await report(resultsPath)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 4)
            XCTAssertEqual(MuterCommand.fullMessage(for: error), "")
        }
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 1 of 3 mutants, from \(resultsPath): the run stopped on an error (mutantNotSwitchedOn)."]
        )
    }

    // Only an error: a run that was interrupted, or has no end line yet, says nothing about its mutants' code.
    func test_aRunThatWasInterrupted_orHasNoEndLine_exits0() async throws {
        for end in [ResultsEnd.make(reason: .interrupted, detail: "SIGINT"), nil] {
            try write([ResultsHeader.make(), alpha3] + [end].compactMap { $0 }, to: resultsPath)

            try await report(resultsPath)
        }

        XCTAssertEqual(printer.linesPassed.count, 2)
    }

    // The run is still going, or was killed or crashed: the report holds what it had tested.
    func test_aFileWithoutAnEndLine_isReported_sayingSo() async throws {
        try write(ResultsHeader.make(), alpha3, to: resultsPath)

        try await report(resultsPath)

        let soFar = ran(MutationTestOutcome(
            mutations: [mutation("Sources/Alpha.swift", line: 3, .failed)],
            coverageSkipped: true,
            testDuration: 31.25
        ))
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: soFar)])
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 1 of 3 mutants, from \(resultsPath): "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }

    // Standard output holds the report alone, so `-f json > report.json` stays valid JSON: the warning of the run's
    // suspect tests is said on standard error, after what the file holds, and without the run's emoji.
    func test_suspectTests_areSaidOnStandardErrorOnly_withoutEmoji() async throws {
        let timing = FailedTestLine.FailedTest(name: "timing()", location: "TimingTests.swift:9:5")
        let files = (0 ..< 10).map { "Sources/F\($0).swift" }
        let header: [any Encodable] = [ResultsHeader.make(mutantsDiscovered: 11, mutantsToTest: 11)]
        let kills: [any Encodable] = files.map { MutantResult.make(path: $0, line: 3, killedBy: [timing]) }
        let survivorAndEnd: [any Encodable] = [zeta9, ResultsEnd.make(recorded: 11)]
        try write(header + kills + survivorAndEnd, to: resultsPath)
        let outcome = ran(
            MutationTestOutcome(
                mutations: files.map { path in
                    mutation(path, line: 3, .failed, killingTests: .init(tests: [timing], count: 1, isComplete: true))
                } + [mutation("Sources/Zeta.swift", line: 9, .passed)],
                coverage: .null,
                coverageSkipped: true,
                testDuration: 100.5,
                newVersion: ""
            ),
            header: .make(mutantsDiscovered: 11, mutantsToTest: 11)
        )
        let status = "Report of 11 of 11 mutants, from \(resultsPath): the run finished."
        let warning = "1 test may fail whatever the mutant: it failed for mutants in at least 15% of the 10 files "
            + "with a killed mutant (timing() in 10). Without its failures, the mutation score would be 0%, not 90%."

        try await report(resultsPath)

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: outcome)])
        XCTAssertEqual(standardError.linesPassed, [status, warning])

        let output = "\(directory)/report.json"
        try await report(resultsPath, "-f", "json", "-o", output)

        XCTAssertEqual(
            try parsedJSON(String(contentsOfFile: output, encoding: .utf8)),
            try parsedJSON(JsonReporter().report(from: outcome))
        )
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: outcome)], "nothing more")
        XCTAssertEqual(
            standardError.linesPassed,
            [status, warning, status, warning, "Mutation score: 90% (10 killed, 1 survived)"]
                + ["Report saved to \(output)"]
        )
    }

    // `--summary` saves the run's summary.json, of how its last session ended, naming the report and the file.
    func test_theSummary_isSavedWhereAsked() async throws {
        let interrupted = ResultsEnd.make(reason: .interrupted, detail: "SIGTERM")
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, interrupted, to: resultsPath)
        let summaryPath = "\(directory)/summary.json"
        let output = "\(directory)/report.html"

        try await report(resultsPath, "-f", "html", "-o", output, "--summary", summaryPath)

        let data = try Data(contentsOf: URL(fileURLWithPath: summaryPath))
        let summary = try JSONDecoder().decode(RunSummary.self, from: data)
        XCTAssertEqual(summary, RunSummary(of: expected, ended: .interrupted, endDetail: "SIGTERM", report: output))
        XCTAssertEqual(summary.run?.resultsFiles, [resultsPath])
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")
    }

    // Saving replaces whatever is there, so never the results file, nor the report.
    func test_theSummary_isNeverSavedOverTheResultsFile_orTheReport() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/report.txt"

        await AssertThrowsError(try await report(resultsPath, "--summary", resultsPath))
        await AssertThrowsError(try await report(resultsPath, "-o", output, "--summary", output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertTrue(try String(contentsOfFile: resultsPath, encoding: .utf8).contains(#""kind":"end""#))
    }

    // Two spellings of one new file, on a volume that ignores case, are known to be one only once the report is saved:
    // the summary is then refused, and the report kept.
    func test_theSummary_isNeverSavedOverTheReport_spelledInAnotherCase() async throws {
        let probe = "\(directory)/probe"
        XCTAssertTrue(FileManager.default.createFile(atPath: probe, contents: nil))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(directory)/PROBE"), "This volume tells case apart")
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/Report.txt"

        await AssertThrowsError(try await report(resultsPath, "-o", output, "--summary", "\(directory)/report.txt")) {
            let refusal = "The report and the summary can't both be saved to \(output)"
            XCTAssertEqual($0 as? MuterError, .literal(reason: refusal))
        }
        let saved = try String(contentsOfFile: output, encoding: .utf8)
        XCTAssertTrue(saved.contains("Sources/Zeta.swift:9:22 survived"), "the report, not the summary: \(saved)")
    }

    // A refusal names the option whose path it refuses.
    func test_aSummaryPathThatIsAFolder_isRefusedAsTheSummarys() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--summary", directory)) {
            let refusal = "\(directory) is a folder: name the file to save the summary to"
            XCTAssertEqual($0 as? MuterError, .literal(reason: refusal))
        }
        await AssertThrowsError(try await report(resultsPath, "--summary", resultsPath)) {
            let refusal = "\(resultsPath) is the results file the report is made from: choose another summary path"
            XCTAssertEqual($0 as? MuterError, .literal(reason: refusal))
        }
    }

    // The run stopped before any mutant finished.
    func test_aFileWithOnlyItsHeader_givesAnEmptyReport() async throws {
        try write(ResultsHeader.make(), to: resultsPath)

        try await report(resultsPath, "-f", "json")

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            try parsedJSON(printer.linesPassed.first ?? ""),
            try parsedJSON(JsonReporter().report(from: ran(MutationTestOutcome())))
        )
        XCTAssertEqual(
            standardError.linesPassed,
            [
                "Report of 0 of 3 mutants, from \(resultsPath): "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }

    // MARK: - Shards

    func test_severalShardsResultsFiles_areMergedIntoTheWholeRunsReport() async throws {
        let first = "\(directory)/first.jsonl"
        let second = "\(directory)/second.jsonl"
        try write(
            shardHeader(1, mutantsDiscovered: 2),
            zeta9,
            alpha3,
            ResultsEnd.make(testDurationSeconds: 60),
            to: first
        )
        try write(shardHeader(2, mutantsDiscovered: 1), zeta10, ResultsEnd.make(), to: second)

        try await report(second, first)

        // The shards' files in shard order; their details are the first shard's.
        let reported = expected(from: [first, second], header: shardHeader(1, mutantsDiscovered: 2))
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: reported)])
        XCTAssertEqual(standardError.linesPassed, [
            "Report of 3 of 3 mutants, merged from the results files of 2 of 2 shards.",
            "Shard 1 of 2, 2 of its 2 mutants, from \(first): the run finished.",
            "Shard 2 of 2, 1 of its 1 mutant, from \(second): the run finished.",
        ])
    }

    // As a merge of one: a CI job's glob that finds only one shard's file fails as one that finds two of three would.
    func test_oneShardsFile_isReportedAsTheShard_andLacksTheOthers() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }

        XCTAssertTrue(
            printer.linesPassed.first?.contains("Only the mutants in shard 1 of 2 were tested, of 3 discovered") == true
        )
        XCTAssertEqual(standardError.linesPassed, [
            "Report of 2 of 2 mutants in shard 1 of 2, from \(resultsPath): the run finished.",
            "No results file was given for shard 2 of 2, which holds 1 mutant.",
        ])
    }

    // A small change can leave every other shard empty, and then one file is the whole run.
    func test_oneShardsFile_whoseOthersAreEmpty_isTheWholeRunsReport() async throws {
        try write(
            shardHeader(1, mutantsDiscovered: 3, mutantsPerShard: [3, 0]),
            zeta9,
            alpha3,
            zeta10,
            ResultsEnd.make(),
            to: resultsPath
        )

        try await report(resultsPath, "--merge-ignoring", "*.md")

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
        XCTAssertEqual(standardError.linesPassed.last, "Shard 2 of 2 holds no mutant, so it has no results file.")
    }

    // A CI job that checks the merged report fails, as the missing shard's own job may not have.
    func test_aShardThatHoldsMutantsButIsntGiven_isReported_thenExitsAsAnAbortedRunDoes() async throws {
        let split = [2, 1, 1]
        try write(
            shardHeader(1, count: 3, mutantsDiscovered: 2, mutantsPerShard: split),
            zeta9,
            alpha3,
            ResultsEnd.make(),
            to: "\(directory)/1.jsonl"
        )
        try write(
            shardHeader(3, count: 3, mutantsDiscovered: 1, mutantsPerShard: split),
            zeta10,
            ResultsEnd.make(),
            to: "\(directory)/3.jsonl"
        )

        await AssertThrowsError(try await report("\(directory)/1.jsonl", "\(directory)/3.jsonl")) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            standardError.linesPassed.last,
            "No results file was given for shard 2 of 3, which holds 1 mutant."
        )
    }

    func test_shardsThatCantBeMerged_areRefused_withExitStatus1() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), to: "\(directory)/1.jsonl")
        try write(ResultsHeader.make(), to: "\(directory)/whole.jsonl")

        await assertRefused(
            try await report("\(directory)/1.jsonl", "\(directory)/whole.jsonl"),
            MergeRefused(reasons: [.notAShard(path: "\(directory)/whole.jsonl")]),
            saying: """
            Error: SwiftMutator won't merge these results files, so that the report holds only results a whole run \
            would give:
              - '\(directory)/whole.jsonl' isn't the results file of a shard (run --shard), so it can't be merged \
            with others.
            """
        )
    }

    func test_neverWritesOverAnyOfTheShardsFiles() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), to: "\(directory)/1.jsonl")
        try write(shardHeader(2, mutantsDiscovered: 1), to: "\(directory)/2.jsonl")

        await assertRefused(
            try await report("\(directory)/1.jsonl", "\(directory)/2.jsonl", "-o", "\(directory)/2.jsonl"),
            MuterError.literal(
                reason: "\(directory)/2.jsonl is one of the results files the report is made from: choose another "
                    + "output path"
            )
        )
    }

    // How many files a CI job's glob finds is up to the shards, so a merge's flags are no mistake with one.
    func test_mergeOptions_areAcceptedWithAnyNumberOfFiles() throws {
        for files in [["r.jsonl"], ["1.jsonl", "2.jsonl"]] {
            let arguments = ["report"] + files + ["--force-merge", "--merge-ignoring", "*.md"]
            let command = try MuterCommand.parseAsRoot(arguments)
            let report = try XCTUnwrap(command as? Report)
            XCTAssertTrue(report.forceMerge)
            XCTAssertEqual(report.mergeIgnoring, ["*.md"])
        }
    }

    // CI can gate on a results file it already has. The report and the status come first, and the verdict last, on
    // standard error; the status is the threshold's own, and ArgumentParser prints nothing more.
    // The run's header records its propertyTests, which the report splits the kills by; --property-tests replaces
    // them, and without either there is no such section.
    func test_propertyTests_splitTheKills_asTheHeaderRecordsThem_unlessTheFlagGivesOthers() async throws {
        let ordered = FailedTestLine.FailedTest(name: "ordered()", location: "SortProperties.swift:8:5")
        let sum = FailedTestLine.FailedTest(name: "sum()", location: "SumTests.swift:3:5")
        let configured = MuterConfiguration(
            executable: "/usr/bin/swift", arguments: ["test"], propertyTests: ["*Properties*"]
        )
        let lines: [any Encodable] = [
            ResultsHeader.make(mutantsDiscovered: 2, mutantsToTest: 2, configuration: configured),
            MutantResult.make(path: "Sources/Sort.swift", line: 3, killedBy: [ordered]),
            MutantResult.make(path: "Sources/Sum.swift", line: 3, killedBy: [sum]),
            ResultsEnd.make(recorded: 2),
        ]
        try write(lines, to: resultsPath)

        try await report(resultsPath)
        try await report(resultsPath, "--property-tests", "sum()", "--property-tests", "ordered()")
        try await report(resultsPath, "-f", "json")

        XCTAssertEqual(printer.linesPassed.count, 3)
        let (recorded, flagged) = (printer.linesPassed[0], printer.linesPassed[1])
        XCTAssertTrue(recorded.contains(#"matches "*Properties*"."#), recorded)
        XCTAssertTrue(recorded.contains("examples alone were recorded killing 1 (50%), properties alone 1 (50%)"))
        XCTAssertTrue(flagged.contains(#"matches "sum()" or "ordered()"."#), flagged)
        XCTAssertTrue(flagged.contains("examples alone were recorded killing 0 (0%), properties alone 2 (100%)"))
        XCTAssertNotNil(try parsedJSON(printer.linesPassed[2])["propertyKillSummary"])

        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try await report(resultsPath)
        XCTAssertFalse(try XCTUnwrap(printer.linesPassed.last).contains("Examples and Properties"))
    }

    func test_anEmptyPropertyTestsGlob_isAUsageError() {
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["report", resultsPath, "--property-tests", ""])) { error in
            XCTAssertEqual(
                MuterCommand.message(for: error),
                "--property-tests: a glob can't be empty, as it would match no test."
            )
        }
        XCTAssertThrowsError(try MuterCommand.parseAsRoot(["run", "--property-tests", ""]))
        XCTAssertNoThrow(try MuterCommand.parseAsRoot(["run", "--property-tests", "*Properties*"]))
    }

    func test_failUnder_aScoreBelowIt_exits2_afterTheReport() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--fail-under", "50")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 2)
            XCTAssertEqual(MuterCommand.fullMessage(for: error), "")
        }
        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
        XCTAssertEqual(standardError.linesPassed, [
            "Report of 3 of 3 mutants, from \(resultsPath): the run finished.",
            "Mutation score 33.3% is below the required 50%.",
        ])
    }

    // Exactly 33.33…%, which the threshold's one decimal shows as it is.
    func test_failUnder_aScoreAtOrAboveIt_exits0() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath, "--fail-under", "33.3")

        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% meets the required 33.3%.")
    }

    // The run's error wins (#110): the score of what it tested isn't the project's.
    func test_failUnder_ofARunThatStoppedOnAnError_isntChecked_andExitsAsTheRunDid() async throws {
        for (detail, status) in [("tooManyBuildErrors", ExitCode.abortedMidRun), ("MuterError", .stoppedOnAnError)] {
            let end = ResultsEnd.make(reason: .aborted, detail: detail)
            try write(ResultsHeader.make(), alpha3, end, to: resultsPath)

            await AssertThrowsError(try await report(resultsPath, "--fail-under", "100")) { error in
                XCTAssertEqual(error as? ExitCode, status, detail)
            }
            XCTAssertEqual(
                standardError.linesPassed.last,
                "The required 100% isn't checked: the run stopped on an error.",
                detail
            )
        }
    }

    // What was tested is checked, and the verdict says it is partial; the job that ran it already got its signal.
    func test_failUnder_ofARunThatDidntFinish_checksWhatWasTested() async throws {
        for end in [ResultsEnd.make(reason: .interrupted, detail: "SIGINT"), nil] {
            try write([ResultsHeader.make(), zeta9] + [end].compactMap { $0 }, to: resultsPath)

            await AssertThrowsError(try await report(resultsPath, "--fail-under", "50")) { error in
                XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            }
            XCTAssertEqual(
                standardError.linesPassed.last,
                "Mutation score 0.0% is below the required 50%. Only 1 of 3 mutants have results, as the run didn't "
                    + "finish."
            )
        }
    }

    // The merged score is the whole run's.
    func test_failUnder_ofMergedShards_checksTheMergedScore() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1), zeta10, ResultsEnd.make(), to: second)

        await AssertThrowsError(try await report(first, second, "--fail-under", "34")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% is below the required 34%.")

        try await report(first, second, "--fail-under", "33")
        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% meets the required 33%.")
    }

    // As without the threshold: the merge lacks results, so the whole run didn't test every mutant.
    func test_failUnder_ofShardsThatLackResults_isntChecked_andExits4() async throws {
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--fail-under", "10")) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(
            standardError.linesPassed.last,
            "The required 10% isn't checked: the merged report lacks results."
        )
    }

    // Scripts read the verdict from the summary; the threshold checked, which needn't be the run's own.
    func test_failUnder_isRecordedInTheSummary() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        await AssertThrowsError(try await report(resultsPath, "--fail-under", "50", "--summary", summaryPath))

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let gate = try XCTUnwrap(parsedJSON(saved)["gate"] as? NSDictionary, saved)
        XCTAssertEqual(gate, ["failUnder": 50, "passed": false, "score": 100.0 / 3])
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "Summary saved to \(summaryPath)",
            "Mutation score 33.3% is below the required 50%.",
        ])
    }

    // `report` reads no configuration, so the run's own failUnder, which its header records, is never checked: only
    // `--fail-under` sets a threshold, so a plain `report` of a low score exits 0 whatever the run required.
    func test_failUnder_theRunsOwn_isntChecked_onlyTheFlag() async throws {
        let configuration = MuterConfiguration(executable: "/usr/bin/swift", arguments: ["test"], failUnder: 80)
        let header = ResultsHeader.make(configuration: configuration)
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        try await report(resultsPath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let summary = try parsedJSON(saved)
        XCTAssertNil(summary["gate"], saved)
        let run = try XCTUnwrap(summary["run"] as? NSDictionary, saved)
        XCTAssertEqual((run["configuration"] as? NSDictionary)?["failUnder"] as? Double, 80, saved)
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")
        XCTAssertFalse(standardError.linesPassed.contains { $0.contains("required") }, "\(standardError.linesPassed)")

        // The flag's threshold is checked in its place, below the run's own.
        try await report(resultsPath, "--fail-under", "30", "--summary", summaryPath)

        let gate = try parsedJSON(String(contentsOfFile: summaryPath, encoding: .utf8))["gate"] as? NSDictionary
        XCTAssertEqual(gate?["failUnder"] as? Double, 30)
        XCTAssertEqual(standardError.linesPassed.last, "Mutation score 33.3% meets the required 30%.")
    }

    func test_failUnder_withoutIt_theSummaryHasNoGate() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let summaryPath = "\(directory)/summary.json"

        try await report(resultsPath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        XCTAssertNil(try parsedJSON(saved)["gate"], saved)
        XCTAssertEqual(standardError.linesPassed.last, "Summary saved to \(summaryPath)")
    }
}

private extension ReportCommandTests {
    /// The header of shard `index` of `count` of the 3 mutants, which holds `mutantsDiscovered` of them: Alpha.swift:3
    /// and Zeta.swift:9 in shard 1, Zeta.swift:10 in shard 2, by default.
    func shardHeader(
        _ index: Int,
        count: Int = 2,
        mutantsDiscovered: Int,
        mutantsPerShard: [Int] = [2, 1]
    ) -> ResultsHeader {
        ResultsHeader.make(
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsDiscovered,
            project: ProjectTree(
                listedBy: .git,
                files: ["Sources/Zeta.swift": "ab12"],
                excluded: [],
                treeSHA256: "cd34"
            ),
            shard: .make(
                index: index,
                count: count,
                mutantsInAllShards: mutantsPerShard.reduce(0, +),
                mutantsPerShard: mutantsPerShard
            )
        )
    }

    /// Runs `swift-mutator report` with `arguments`.
    func report(_ arguments: String...) async throws {
        try await report(arguments)
    }

    /// Runs `swift-mutator report` with `arguments`.
    func report(_ arguments: [String]) async throws {
        let command = try MuterCommand.parseAsRoot(["report"] + arguments)
        guard let report = command as? Report else {
            return XCTFail("Expected the report command, got \(command)")
        }
        try await report.run()
    }

    /// Checks that `expression` throws `expected`, which ArgumentParser shows as `message` on standard error, with exit
    /// status 1, and that nothing else is printed on either.
    func assertRefused<Failure: Error & Equatable>(
        _ expression: @autoclosure () async throws -> Void,
        _ expected: Failure,
        saying message: String? = nil,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await AssertThrowsError(try await expression(), context, file: file, line: line) { error in
            XCTAssertEqual(error as? Failure, expected, context, file: file, line: line)
            XCTAssertEqual(MuterCommand.exitCode(for: error), .failure, context, file: file, line: line)
            if let message {
                XCTAssertEqual(MuterCommand.fullMessage(for: error), message, context, file: file, line: line)
            }
        }
        XCTAssertEqual(printer.linesPassed, [], context, file: file, line: line)
        XCTAssertEqual(standardError.linesPassed, [], context, file: file, line: line)
    }

    /// The log folders of a run resumed once, in `<directory>/project_muter_logs`: the first session's, which holds the
    /// results file, starting with `header`, and the resumed session's, which holds only its note naming the file.
    func makeAResumedRunsLogFolders(
        header: ResultsHeader = .make()
    ) throws -> (first: String, resumed: String) {
        let logs = "\(directory)/project_muter_logs"
        let first = "\(logs)/session 1"
        let resumed = "\(logs)/session 2"
        for folder in [first, resumed] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: "\(first)/results.jsonl")
        try writeNote(pointingTo: "\(first)/results.jsonl", session: 2, in: resumed)
        return (first, resumed)
    }

    /// Writes the note the `session`th session of a resumed run leaves in its log folder, `folder`.
    func writeNote(pointingTo path: String, session: Int, in folder: String) throws {
        let note = Data(ResultsFile.note(pointingTo: path, session: session).utf8)
        try note.write(to: URL(fileURLWithPath: "\(folder)/\(ResultsFile.noteFileName)"))
    }

    /// A triage file at `path` with `label` for `zeta9`.
    func writeTriage(to path: String, label: String) throws {
        try """
        mutants:
        - mutant: Sources/Zeta.swift:9:22 RelationalOperatorReplacement
          label: \(label)
        """.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func XCTAssertThrowsErrorAsync(
        _ expression: @autoclosure () async throws -> Void,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected an error", line: line)
        } catch {}
    }

    /// JSONEncoder promises no order of keys, so JSON compares parsed.
    func parsedJSON(_ text: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary, text)
    }

    func write(_ records: any Encodable..., to path: String) throws {
        try write(records, to: path)
    }

    func write(_ records: [any Encodable], to path: String) throws {
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// The mutant `MutantResult.make` records at `line` of `path`, as the run reported it.
    func mutation(
        _ path: String,
        line: Int,
        _ outcome: TestSuiteOutcome,
        killingTests: MutationTestOutcome.KillingTests? = nil
    ) -> MutationTestOutcome.Mutation {
        MutationTestOutcome.Mutation(
            testSuiteOutcome: outcome,
            mutationPoint: MutationPoint(
                mutationOperatorId: .ror,
                filePath: "/project_mutated/\(path)",
                position: MutationPosition(utf8Offset: 3361, line: line, column: 22)
            ),
            mutationSnapshot: .make(before: ">", after: "<", description: "changed > to <"),
            originalProjectDirectoryUrl: URL(fileURLWithPath: "/project", isDirectory: true),
            mutatedProjectDirectoryURL: URL(fileURLWithPath: "/project_mutated", isDirectory: true),
            killingTests: killingTests,
            reusedFrom: nil,
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: 22, occurrence: 0),
            durationSeconds: 31.25
        )
    }
}
