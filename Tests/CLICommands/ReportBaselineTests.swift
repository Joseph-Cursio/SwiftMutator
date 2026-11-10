import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// `swift-mutator report --baseline` and `--write-baseline`, run on results files in a temporary folder: the survivors
/// compared with a baseline file's, the scope it refuses, and the results that make one.
final class ReportBaselineTests: MuterTestCase {
    var directory = ""
    var resultsPath: String { "\(directory)/results.jsonl" }
    var baselinePath: String { "\(directory)/\(BaselineFile.fileName)" }

    let zeta9 = MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed)
    let alpha3 = MutantResult.make(path: "Sources/Alpha.swift", line: 3, outcome: .failed)
    let zeta10 = MutantResult.make(path: "Sources/Zeta.swift", line: 10, outcome: .passed)

    /// What `ResultsHeader.make()` records of its scope.
    let scope = BaselineScope(
        header: ResultsHeader.make()
    )

    override func setUpWithError() throws {
        try super.setUpWithError()

        directory = try makeTemporaryDirectory()
    }

    // After setUpWithError, which XCTest calls first: MuterTestCase installs the spies in both.
    override func setUp() {
        super.setUp()

        current.fileManager = FileManager.default
    }

    func test_aNewSurvivor_exits2_afterTheReport_andIsSaidLast() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [zeta9])

        await AssertThrowsError(try report(resultsPath, "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 2)
        }
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "1 new survivor against the baseline file \(baselinePath), more than the 0 allowed: 1 still survive, 0 "
                + "fixed. 1 was matched without its line, as its file changed since it was tested, or can't be read.",
            "  Sources/Zeta.swift:10:22 RelationalOperatorReplacement: > → <",
        ])

        try report(resultsPath, "--baseline", baselinePath, "--max-new-survivors", "1")
        XCTAssertTrue(
            standardError.linesPassed.contains { $0.hasPrefix("1 new survivor against the baseline file") },
            "\(standardError.linesPassed)"
        )
    }

    // Scripts read the verdict from the summary, beside the score's.
    func test_theVerdict_isRecordedInTheSummary() throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [zeta9, zeta10, alpha3])
        let summaryPath = "\(directory)/summary.json"

        try report(resultsPath, "--baseline", baselinePath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: AnyHashable])
        let verdict = try XCTUnwrap(json["newSurvivors"] as? [String: AnyHashable], saved)
        XCTAssertEqual(verdict["passed"] as? Bool, true)
        XCTAssertEqual(verdict["stillSurvive"] as? Int, 2)
        XCTAssertEqual(verdict["fixed"] as? Int, 1)
        XCTAssertEqual(verdict["baseline"] as? String, baselinePath)
        XCTAssertNil(json["gate"])
    }

    // Before any report, so a CI job's log ends with why.
    func test_aBaselineFileOfAnotherScope_isRefused_andExits8() async throws {
        try write(ResultsHeader.make(operators: ["SwapTernary"]), zeta9, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [])

        await AssertThrowsError(try report(resultsPath, "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .baselineRefused)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 8)
        }
        XCTAssertEqual(printer.linesPassed, [])
        let message = standardError.linesPassed.joined(separator: "\n")
        XCTAssertTrue(
            message.contains(
                #"operators is ["RelationalOperatorReplacement"] in the baseline file, and ["SwapTernary"] in these "#
                    + "results."
            ),
            message
        )
    }

    func test_noBaselineFile_isRefused_andExits8_beforeTheResultsAreRead() async throws {
        await AssertThrowsError(try report("\(directory)/none.jsonl", "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .baselineRefused)
        }
        XCTAssertEqual(standardError.linesPassed, [
            "SwiftMutator won't compare the survivors with the baseline file \(Logger.shellQuoted(baselinePath)):\n"
                + "  - There is no baseline file there. Write one with --write-baseline.",
        ])
    }

    // The run's error wins: what it tested isn't the project's.
    func test_aRunThatStoppedOnAnError_isntCompared_andExitsAsTheRunDid() async throws {
        let end = ResultsEnd.make(reason: .aborted, detail: "tooManyBuildErrors")
        try write(ResultsHeader.make(), zeta9, end, to: resultsPath)
        try writeBaseline(survivors: [])

        await AssertThrowsError(try report(resultsPath, "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(
            standardError.linesPassed.last,
            "The survivors aren't compared with the baseline file \(baselinePath): the run stopped on an error."
        )
    }

    // A main-branch job's: the file it compared with is replaced with this run's.
    func test_aFinishedRun_writesABaselineFile_overTheOneItComparesWith() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [zeta9])

        await AssertThrowsError(
            try report(resultsPath, "--baseline", baselinePath, "--write-baseline", baselinePath)
        )

        XCTAssertTrue(standardError.linesPassed.contains("Baseline file saved to \(baselinePath)"))
        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10])
        XCTAssertEqual(written.scope, scope)
        XCTAssertEqual(written.swiftMutator, "1.0.0")
        XCTAssertEqual(written.score, .init(killed: 1, scored: 3))
        // Compared with it now, nothing is new.
        try report(resultsPath, "--baseline", baselinePath)
    }

    func test_aRunThatDidntFinish_writesNone_andSaysWhy() throws {
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, end, to: resultsPath)

        try report(resultsPath, "--write-baseline", baselinePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
        XCTAssertTrue(
            standardError.linesPassed.contains(
                "No baseline file was saved to \(baselinePath): the run didn't finish, and a baseline file holds a "
                    + "whole run's survivors."
            ),
            "\(standardError.linesPassed)"
        )
    }

    // Every shard of a split, merged, is the whole run; some of them aren't.
    func test_mergedShards_writeOne_onlyWhenEveryShardIsGiven() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1), zeta10, ResultsEnd.make(), to: second)

        try report(first, second, "--write-baseline", baselinePath)

        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10])

        try FileManager.default.removeItem(atPath: baselinePath)
        await AssertThrowsError(try report(first, "--write-baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
        XCTAssertTrue(
            standardError.linesPassed.contains {
                $0.hasPrefix("No baseline file was saved to \(baselinePath): the merged report lacks results")
            },
            "\(standardError.linesPassed)"
        )
    }

    // Each shard split its own discovery, so their merge may miss mutants: it isn't known to be a whole run.
    func test_mergedShards_thatDiscoveredDifferentMutants_writeNone() throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1, allKeysSHA256: "b22"), zeta10, ResultsEnd.make(), to: second)

        try report(first, second, "--write-baseline", baselinePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
        XCTAssertTrue(
            standardError.linesPassed.contains(
                "No baseline file was saved to \(baselinePath): the shards' runs didn't discover the same mutants, and "
                    + "a baseline file holds a whole run's survivors."
            ),
            "\(standardError.linesPassed)"
        )
    }

    // A run of one mutant compares no survivors, and records every operator and coverage skipped, so its scope isn't
    // refused: it is said not to be compared, as the run says it.
    func test_aOneMutantRunsResults_areNotCompared_norTheirScopeRefused() throws {
        let header = ResultsHeader.make(operators: ["SwapTernary"], mutant: "Sources/Zeta.swift:9:22")
        try write(header, zeta9, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [])

        try report(resultsPath, "--baseline", baselinePath)

        XCTAssertEqual(
            standardError.linesPassed.last,
            "The survivors aren't compared with the baseline file \(baselinePath): one mutant's run (--mutant) isn't "
                + "the project's."
        )
    }

    // Nothing is reported, but what was asked for is said not done.
    func test_resultsThatStoppedBeforeTheirFirstMutant_sayNoBaselineFileWasSaved() async throws {
        let stopped = ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")
        try write(stopped, to: resultsPath)
        try writeBaseline(survivors: [])

        await AssertThrowsError(
            try report(resultsPath, "--baseline", baselinePath, "--write-baseline", "\(directory)/new.yml")
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(directory)/new.yml"))
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "The survivors aren't compared with the baseline file \(baselinePath): the run stopped before its first "
                + "mutant.",
            "No baseline file was saved to \(directory)/new.yml: the run stopped before its first mutant, and a "
                + "baseline file holds a whole run's survivors.",
        ])
    }

    // As `--fail-under` says it: the verdict is on the results the file holds. An entry is then matched only at its own
    // key, as the mutants the run didn't reach aren't known.
    func test_anUnfinishedRun_isCompared_sayingHowManyHaveResults() throws {
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        try write(ResultsHeader.make(mutantsDiscovered: 10), zeta9, alpha3, end, to: resultsPath)
        try writeBaseline(survivors: [zeta9])

        try report(resultsPath, "--baseline", baselinePath)

        XCTAssertEqual(
            standardError.linesPassed.last,
            "No new survivors against the baseline file \(baselinePath): 1 still survive, 0 fixed. 1 was matched "
                + "without its line, as its file changed since it was tested, or can't be read. Only 2 of 10 mutants "
                + "have results, as the run didn't finish."
        )
    }

    // On a volume that ignores case, two spellings of one new file are known to be one only once it's there: the
    // summary mustn't replace the baseline file saved just before it.
    func test_aSummaryAtTheBaselineFilesPath_inAnotherCase_isRefused_onceTheFileIsThere() async throws {
        let probe = "\(directory)/Probe"
        try Data().write(to: URL(fileURLWithPath: probe))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(directory)/probe"), "the volume heeds case")
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        let saved = "\(directory)/out/Baseline.yml"

        await AssertThrowsError(
            try report(resultsPath, "--write-baseline", saved, "--summary", "\(directory)/out/baseline.yml")
        ) { error in
            XCTAssertTrue("\(error)".contains("can't both be saved to"), "\(error)")
        }
        XCTAssertTrue(standardError.linesPassed.isEmpty, "refused before anything is said")
        XCTAssertNoThrow(try BaselineFile.load(at: saved, using: FileManager.default))
    }

    // A run moves into the project's copy before it saves the file, so a relative path is made absolute as the flags
    // are read, against the folder the command was given in, as `-o`'s is: else the file goes into the copy.
    func test_writeBaseline_isMadeAbsolute_againstTheCurrentFolder() throws {
        let folder = FileManager.default.currentDirectoryPath
        XCTAssertEqual(current.fileManager.currentDirectoryPath, folder)
        for (given, saved) in [
            ("muter.baseline.yml", "\(folder)/muter.baseline.yml"),
            ("ci/muter.baseline.yml", "\(folder)/ci/muter.baseline.yml"),
            ("/out/muter.baseline.yml", "/out/muter.baseline.yml"),
            ("~/muter.baseline.yml", URL.expandingTilde("~/muter.baseline.yml")),
        ] {
            let run = try XCTUnwrap(MuterCommand.parseAsRoot(["run", "--write-baseline", given]) as? Run)
            XCTAssertEqual(run.runOptions.writeBaseline, saved, given)
            let report = try XCTUnwrap(
                MuterCommand.parseAsRoot(["report", "r.jsonl", "--write-baseline", given]) as? Report
            )
            XCTAssertEqual(report.reportOptions.writeBaseline, saved, given)
        }
    }

    // Saving it would destroy what the report is made from.
    func test_writeBaseline_atTheResultsFile_isRefused() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try report(resultsPath, "--write-baseline", resultsPath)) { error in
            XCTAssertTrue(
                "\(error)".contains(
                    "is the results file the report is made from: choose another --write-baseline path"
                ),
                "\(error)"
            )
        }
    }
}
