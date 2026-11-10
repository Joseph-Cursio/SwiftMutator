import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// `swift-mutator report`: parsed as the command line gives it, then run on results files in a temporary folder.
final class ReportCommandTests: MuterTestCase {
    var directory = ""
    var resultsPath: String { "\(directory)/results.jsonl" }

    /// Discovery puts Alpha.swift first, and Zeta.swift's line 9 before its line 10, though as text, as in a switch ID,
    /// 10 comes first; the run wrote them in the order they finished in.
    let zeta9 = MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed)
    let alpha3 = MutantResult.make(path: "Sources/Alpha.swift", line: 3, outcome: .failed)
    let zeta10 = MutantResult.make(path: "Sources/Zeta.swift", line: 10, outcome: .passed)

    /// The outcome the run reported: `ResultsHeader.make()` records a run that skipped coverage.
    var expected: MutationTestOutcome {
        expected(from: [resultsPath])
    }

    /// `outcome`, of the results files at `paths`, `resultsPath` alone by default, each file's last header `header`.
    func ran(
        _ outcome: MutationTestOutcome,
        from paths: [String]? = nil,
        header: ResultsHeader = .make()
    ) -> MutationTestOutcome {
        var outcome = outcome
        outcome.run = RunDetails(of: (paths ?? [resultsPath]).map { ($0, [header]) })
        return outcome
    }

    /// The outcome the run reported, of the results files at `paths`, each of whose last header is `header`.
    func expected(from paths: [String], header: ResultsHeader = .make()) -> MutationTestOutcome {
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

        XCTAssertEqual(printer.linesPassed.first?.contains("Triaged: equivalent"), true, "\(printer.linesPassed)")
    }

    func test_showsTheLabelsInTheCurrentFolder_whenTheRunsProjectHasNone() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        try writeTriage(to: "\(directory)/\(TriageFile.fileName)", label: "missing-test")
        let before = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(directory)
        defer { FileManager.default.changeCurrentDirectoryPath(before) }

        try await report(resultsPath)

        XCTAssertEqual(
            printer.linesPassed.first?.contains("Triaged: missing test"),
            true,
            "\(printer.linesPassed)"
        )
    }

    func test_triageFlag_namesTheFile_whichMustBeThere() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)
        let file = "\(directory)/labels.yml"

        await XCTAssertThrowsErrorAsync(try await report(resultsPath, "--triage", file))

        try writeTriage(to: file, label: "tool-limitation")
        try await report(resultsPath, "--triage", file)
        XCTAssertEqual(
            printer.linesPassed.first?.contains("Triaged: tool limitation"),
            true,
            "\(printer.linesPassed)"
        )
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
        // A file where its folder would be, which no folder can be made in place of.
        XCTAssertTrue(FileManager.default.createFile(atPath: "\(directory)/notAFolder", contents: nil))
        let output = "\(directory)/notAFolder/report.txt"

        await assertRefused(
            try await report(resultsPath, "-o", output),
            MuterError.literal(reason: "SwiftMutator could not save the report to \(output)"),
            saying: "Error: SwiftMutator could not save the report to \(output)"
        )
    }

    // CI jobs name a report in a folder they haven't made, such as out/report.txt.
    func test_aReportsMissingFolders_areMade() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let output = "\(directory)/out/reports/report.txt"

        try await report(resultsPath, "-o", output, "--summary", "\(directory)/out/summaries/summary.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(directory)/out/summaries/summary.json"))
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
}
