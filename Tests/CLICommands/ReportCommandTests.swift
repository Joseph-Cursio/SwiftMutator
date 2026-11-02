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
        MutationTestOutcome(
            mutations: [
                mutation("Sources/Alpha.swift", line: 3, .failed),
                mutation("Sources/Zeta.swift", line: 9, .passed),
                mutation("Sources/Zeta.swift", line: 10, .passed),
            ],
            coverage: .null,
            coverageSkipped: true,
            testDuration: 100.5,
            newVersion: ""
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

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
        XCTAssertEqual(
            standardError.linesPassed,
            ["Report of 3 of 3 mutants, from \(folder)/results.jsonl: the run finished."]
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

    // A script that checks the report fails as one that checked the run would: the run exited 255 through `exit(-1)`.
    // The report and the status are still given first, and ArgumentParser prints nothing more.
    func test_aRunThatStoppedOnAnError_isReported_thenExitsAsTheRunDid() async throws {
        let end = ResultsEnd.make(reason: .aborted, detail: "mutantNotSwitchedOn")
        try write(ResultsHeader.make(), alpha3, end, to: resultsPath)

        await AssertThrowsError(try await report(resultsPath)) { error in
            XCTAssertEqual(error as? ExitCode, Report.stoppedOnAnError)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, -1)
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

        let soFar = MutationTestOutcome(
            mutations: [mutation("Sources/Alpha.swift", line: 3, .failed)],
            coverageSkipped: true,
            testDuration: 31.25
        )
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
        let outcome = MutationTestOutcome(
            mutations: files.map { path in
                mutation(path, line: 3, .failed, killingTests: .init(tests: [timing], count: 1, isComplete: true))
            } + [mutation("Sources/Zeta.swift", line: 9, .passed)],
            coverage: .null,
            coverageSkipped: true,
            testDuration: 100.5,
            newVersion: ""
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
        XCTAssertEqual(standardError.linesPassed, [status, warning, status, warning, "Report saved to \(output)"])
    }

    // The run stopped before any mutant finished.
    func test_aFileWithOnlyItsHeader_givesAnEmptyReport() async throws {
        try write(ResultsHeader.make(), to: resultsPath)

        try await report(resultsPath, "-f", "json")

        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(
            try parsedJSON(printer.linesPassed.first ?? ""),
            try parsedJSON(JsonReporter().report(from: MutationTestOutcome()))
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

        XCTAssertEqual(printer.linesPassed, [PlainTextReporter().report(from: expected)])
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
            XCTAssertEqual(error as? ExitCode, Report.stoppedOnAnError)
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
    func test_aShardThatHoldsMutantsButIsntGiven_isReported_thenExitsAsAStoppedRunDoes() async throws {
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
            XCTAssertEqual(error as? ExitCode, Report.stoppedOnAnError)
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
            reusedFrom: nil
        )
    }
}
