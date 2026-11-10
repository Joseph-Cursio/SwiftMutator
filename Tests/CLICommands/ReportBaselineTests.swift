import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

/// `swift-mutator report --baseline` and `--write-baseline`, run on results files in a temporary folder: the survivors
/// compared with a baseline file's, the scope it refuses, and the results that make one.
final class ReportBaselineTests: MuterTestCase {
    private var directory = ""
    private var resultsPath: String { "\(directory)/results.jsonl" }
    private var baselinePath: String { "\(directory)/\(BaselineFile.fileName)" }

    private let zeta9 = MutantResult.make(path: "Sources/Zeta.swift", line: 9, outcome: .passed)
    private let alpha3 = MutantResult.make(path: "Sources/Alpha.swift", line: 3, outcome: .failed)
    private let zeta10 = MutantResult.make(path: "Sources/Zeta.swift", line: 10, outcome: .passed)

    /// What `ResultsHeader.make()` records of its scope.
    private let scope = BaselineScope(
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

        await AssertThrowsError(try await report(resultsPath, "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
            XCTAssertEqual(MuterCommand.exitCode(for: error).rawValue, 2)
        }
        XCTAssertEqual(printer.linesPassed.count, 1)
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "1 new survivor against the baseline file \(baselinePath), more than the 0 allowed: 1 still survive, 0 "
                + "fixed. 1 was matched without its line, as its file changed since it was tested, or can't be read.",
            "  Sources/Zeta.swift:10:22 RelationalOperatorReplacement: > → <",
        ])

        try await report(resultsPath, "--baseline", baselinePath, "--max-new-survivors", "1")
        XCTAssertTrue(
            standardError.linesPassed.contains { $0.hasPrefix("1 new survivor against the baseline file") },
            "\(standardError.linesPassed)"
        )
    }

    // Scripts read the verdict from the summary, beside the score's.
    func test_theVerdict_isRecordedInTheSummary() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [zeta9, zeta10, alpha3])
        let summaryPath = "\(directory)/summary.json"

        try await report(resultsPath, "--baseline", baselinePath, "--summary", summaryPath)

        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? NSDictionary)
        let verdict = try XCTUnwrap(json["newSurvivors"] as? NSDictionary, saved)
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

        await AssertThrowsError(try await report(resultsPath, "--baseline", baselinePath)) { error in
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
        await AssertThrowsError(try await report("\(directory)/none.jsonl", "--baseline", baselinePath)) { error in
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

        await AssertThrowsError(try await report(resultsPath, "--baseline", baselinePath)) { error in
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
            try await report(resultsPath, "--baseline", baselinePath, "--write-baseline", baselinePath)
        )

        XCTAssertTrue(standardError.linesPassed.contains("Baseline file saved to \(baselinePath)"))
        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10])
        XCTAssertEqual(written.scope, scope)
        XCTAssertEqual(written.swiftMutator, "1.0.0")
        XCTAssertEqual(written.score, .init(killed: 1, scored: 3))
        // Compared with it now, nothing is new.
        try await report(resultsPath, "--baseline", baselinePath)
    }

    func test_aRunThatDidntFinish_writesNone_andSaysWhy() async throws {
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, end, to: resultsPath)

        try await report(resultsPath, "--write-baseline", baselinePath)

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

        try await report(first, second, "--write-baseline", baselinePath)

        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10])

        try FileManager.default.removeItem(atPath: baselinePath)
        await AssertThrowsError(try await report(first, "--write-baseline", baselinePath)) { error in
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
    func test_mergedShards_thatDiscoveredDifferentMutants_writeNone() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1, allKeysSHA256: "b22"), zeta10, ResultsEnd.make(), to: second)

        try await report(first, second, "--write-baseline", baselinePath)

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
    func test_aOneMutantRunsResults_areNotCompared_norTheirScopeRefused() async throws {
        let header = ResultsHeader.make(operators: ["SwapTernary"], mutant: "Sources/Zeta.swift:9:22")
        try write(header, zeta9, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [])

        try await report(resultsPath, "--baseline", baselinePath)

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
            try await report(resultsPath, "--baseline", baselinePath, "--write-baseline", "\(directory)/new.yml")
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
    func test_anUnfinishedRun_isCompared_sayingHowManyHaveResults() async throws {
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        try write(ResultsHeader.make(mutantsDiscovered: 10), zeta9, alpha3, end, to: resultsPath)
        try writeBaseline(survivors: [zeta9])

        try await report(resultsPath, "--baseline", baselinePath)

        XCTAssertEqual(
            standardError.linesPassed.last,
            "No new survivors against the baseline file \(baselinePath): 1 still survive, 0 fixed. 1 was matched "
                + "without its line, as its file changed since it was tested, or can't be read. Only 2 of 10 mutants "
                + "have results, as the run didn't finish."
        )
    }

    // After the survivors' verdict: the score fell from 2 of 3 to 1 of 3, past the 2 points allowed.
    func test_aScoreDropPastTheLimit_exits2_andIsSaidAfterTheSurvivors() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [zeta9, zeta10], score: .init(killed: 2, scored: 3))
        let summaryPath = "\(directory)/summary.json"

        await AssertThrowsError(
            try await report(
                resultsPath, "--baseline", baselinePath, "--max-score-drop", "2", "--summary", summaryPath
            )
        ) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "No new survivors against the baseline file \(baselinePath): 2 still survive, 0 fixed. 2 were matched "
                + "without their line, as their files changed since they were tested, or can't be read.",
            "Mutation score 33.3% is 33.3 points below the baseline file \(baselinePath)'s 66.6%, more than the 2 "
                + "allowed.",
        ])
        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? NSDictionary)
        let verdict = try XCTUnwrap(json["scoreDrop"] as? NSDictionary, saved)
        XCTAssertEqual(verdict["passed"] as? Bool, false)
        XCTAssertEqual(verdict["maxScoreDrop"] as? Double, 2)

        try await report(resultsPath, "--baseline", baselinePath, "--max-score-drop", "40")
        XCTAssertEqual(
            standardError.linesPassed.last?.hasSuffix("within the 40 allowed."),
            true,
            "\(standardError.linesPassed)"
        )
    }

    // Its score is of only the mutants it reached, so it isn't the whole project's.
    func test_anUnfinishedRun_doesntCompareTheScore() async throws {
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        try write(ResultsHeader.make(mutantsDiscovered: 10), zeta9, alpha3, end, to: resultsPath)
        try writeBaseline(survivors: [zeta9], score: .init(killed: 9, scored: 10))

        try await report(resultsPath, "--baseline", baselinePath, "--max-score-drop", "2")

        XCTAssertEqual(
            standardError.linesPassed.last,
            "The score isn't compared with the baseline file \(baselinePath)'s: only 2 of 10 mutants have results, "
                + "as the run didn't finish."
        )
    }

    // Every shard, merged, is the whole run, whose score compares; some shards lack results, and exit for that.
    func test_mergedShards_compareTheScore_onlyWhenEveryShardIsGiven() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1), zeta10, ResultsEnd.make(), to: second)
        // Of the shards' scope, which skipped coverage.
        let file = BaselineFile(
            path: baselinePath,
            swiftMutator: "1.0.0",
            score: .init(killed: 1, scored: 3),
            scope: BaselineScope(header: shardHeader(1, mutantsDiscovered: 2)),
            survivors: [zeta9, zeta10].map {
                BaselineSurvivor(
                    mutant: $0.key,
                    outcome: .survived,
                    before: $0.snapshot.before,
                    after: $0.snapshot.after
                )
            }
        )
        XCTAssertTrue(file.save(using: FileManager.default))

        try await report(first, second, "--baseline", baselinePath, "--max-score-drop", "0")
        XCTAssertEqual(
            standardError.linesPassed.last,
            "Mutation score 33.3% is the same as the baseline file \(baselinePath)'s."
        )

        await AssertThrowsError(try await report(first, "--baseline", baselinePath, "--max-score-drop", "0")) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(
            standardError.linesPassed.last,
            "The score isn't compared with the baseline file \(baselinePath)'s: the merged report lacks results."
        )
    }

    // Doubtful kills need no baseline file: here, a kill whose code never ran.
    func test_aDoubtfulKill_exits2_withoutABaselineFile() async throws {
        var neverRan = alpha3
        neverRan.activated = false
        try write(ResultsHeader.make(), zeta9, neverRan, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--max-doubtful-kills", "0")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "1 doubtful kill, more than the 0 allowed: 1 kill whose code never ran.",
            "  Sources/Alpha.swift:3:22 RelationalOperatorReplacement: > → < (its code never ran)",
        ])

        try await report(resultsPath, "--max-doubtful-kills", "1")
        XCTAssertEqual(
            standardError.linesPassed.suffix(2).first,
            "1 doubtful kill, within the 1 allowed: 1 kill whose code never ran."
        )
    }

    // The run's error wins, and nothing is checked; nor for a run that stopped before its first mutant.
    func test_aRunThatStopped_checksNeitherTheScoreDrop_norTheDoubtfulKills() async throws {
        let end = ResultsEnd.make(reason: .aborted, detail: "tooManyBuildErrors")
        try write(ResultsHeader.make(), zeta9, alpha3, end, to: resultsPath)
        try writeBaseline(survivors: [], score: .init(killed: 1, scored: 1))
        let flags = ["--baseline", baselinePath, "--max-score-drop", "2", "--max-doubtful-kills", "0"]

        await AssertThrowsError(try await report(arguments: [resultsPath] + flags)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "The score isn't compared with the baseline file \(baselinePath)'s: the run stopped on an error.",
            "Doubtful kills aren't counted: the run stopped on an error.",
        ])

        let stopped = ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")
        try write(stopped, to: resultsPath)
        await AssertThrowsError(try await report(arguments: [resultsPath] + flags))
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "The score isn't compared with the baseline file \(baselinePath)'s: the run stopped before its first "
                + "mutant.",
            "Doubtful kills aren't counted: the run stopped before its first mutant.",
        ])
    }

    // Each shard split its own discovery, so a mutant one discovered may fall to a shard whose run didn't discover it,
    // and have no result: the merge isn't known to be a whole run, so its score isn't compared, as no baseline file is
    // written from it. Here it would fall 66.7 points below the file's.
    func test_mergedShards_thatDiscoveredDifferentMutants_dontCompareTheScore() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(shardHeader(1, mutantsDiscovered: 2), zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1, allKeysSHA256: "b22"), zeta10, ResultsEnd.make(), to: second)
        let file = BaselineFile(
            path: baselinePath,
            swiftMutator: "1.0.0",
            score: .init(killed: 3, scored: 3),
            scope: BaselineScope(header: shardHeader(1, mutantsDiscovered: 2)),
            survivors: [zeta9, zeta10].map {
                BaselineSurvivor(
                    mutant: $0.key,
                    outcome: .survived,
                    before: $0.snapshot.before,
                    after: $0.snapshot.after
                )
            }
        )
        XCTAssertTrue(file.save(using: FileManager.default))

        try await report(first, second, "--baseline", baselinePath, "--max-score-drop", "2")

        XCTAssertEqual(
            standardError.linesPassed.last,
            "The score isn't compared with the baseline file \(baselinePath)'s: the shards' runs didn't discover the "
                + "same mutants, so some may have no result."
        )
        let summaryPath = "\(directory)/summary.json"
        try await report(
            first, second, "--baseline", baselinePath, "--max-score-drop", "2", "--summary", summaryPath
        )
        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? NSDictionary)
        let verdict = try XCTUnwrap(json["scoreDrop"] as? NSDictionary, saved)
        XCTAssertEqual(verdict["notChecked"] as? String, "discoveriesDiffer")
        XCTAssertNil(verdict["passed"])
    }

    // With mutants left, a resume tests them, then the kills only suspect tests made again alone, so they aren't
    // counted yet; with none left, a resume reruns nothing, so they are counted as they stand.
    func test_anUnfinishedRun_countsTheDoubtfulKills_onlyWithNoMutantLeft() async throws {
        var neverRan = alpha3
        neverRan.activated = false
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGTERM")
        try write(ResultsHeader.make(mutantsDiscovered: 10), zeta9, neverRan, end, to: resultsPath)

        try await report(resultsPath, "--max-doubtful-kills", "0")
        XCTAssertEqual(
            standardError.linesPassed.last,
            "Doubtful kills aren't counted: only 2 of 10 mutants have results, as the run didn't finish. --resume "
                + "tests the rest, then the kills only suspect tests made again alone."
        )

        try write(ResultsHeader.make(mutantsDiscovered: 2), zeta9, neverRan, end, to: resultsPath)
        await AssertThrowsError(try await report(resultsPath, "--max-doubtful-kills", "0")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(
            standardError.linesPassed.suffix(2).first,
            "1 doubtful kill, more than the 0 allowed: 1 kill whose code never ran."
        )
    }

    // Each shard judges its own suspect tests, and tests their kills again alone. A test that reaches enough files
    // only across the shards, 12 here, where each shard has 6, fewer than the 10 a test needs, is suspect in neither,
    // so no shard's run, nor a resume of one, could settle its kills: the merge doesn't count them. A whole run of the
    // same kills does, as its own run would have tested them again alone.
    func test_mergedShards_judgeEachKill_byItsOwnShardsSuspectTests() async throws {
        let broad = FailedTestLine.FailedTest(name: "broad()", location: "BroadTests.swift:3:5")
        let kills = { (shard: Int) in
            (1 ... 6).map { file in
                MutantResult.make(path: "Sources/Shard\(shard)File\(file).swift", line: 3, killedBy: [broad])
            }
        }
        let header = { (index: Int) in
            ResultsHeader.make(
                mutantsDiscovered: 6,
                mutantsToTest: 6,
                project: ProjectTree(listedBy: .git, files: [:], excluded: [], treeSHA256: "cd34"),
                shard: .make(index: index, count: 2, mutantsInAllShards: 12, mutantsPerShard: [6, 6])
            )
        }
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        try write(records: [header(1)] + kills(1) + [ResultsEnd.make()], to: first)
        try write(records: [header(2)] + kills(2) + [ResultsEnd.make()], to: second)

        try await report(first, second, "--max-doubtful-kills", "0")
        XCTAssertEqual(standardError.linesPassed.last, "No doubtful kills.")

        try write(
            records: [ResultsHeader.make(mutantsDiscovered: 12, mutantsToTest: 12)] + kills(1) + kills(2)
                + [ResultsEnd.make()],
            to: resultsPath
        )
        await AssertThrowsError(try await report(resultsPath, "--max-doubtful-kills", "0")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertTrue(
            standardError.linesPassed.contains {
                $0.hasPrefix("12 doubtful kills, more than the 0 allowed: 12 kills only suspect tests made")
            },
            "\(standardError.linesPassed)"
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
            try await report(resultsPath, "--write-baseline", saved, "--summary", "\(directory)/out/baseline.yml")
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

    // The results header records the mutants of code no test ran, so `report` sees what the run saw: a baseline file
    // records them as survivors not covered, and a new one is a new survivor.
    func test_theMutantsOfCodeNoTestRan_areRecorded_andCompared_fromTheResultsHeader() async throws {
        var header = ResultsHeader.make()
        header.mutantsNotCovered = [uncovered("Sources/Zeta.swift", line: 20)]
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath, "--write-baseline", baselinePath)

        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10, 20])
        XCTAssertEqual(written.survivors.map(\.outcome), [.survived, .survived, .notCovered])
        XCTAssertEqual(written.score, .init(killed: 1, scored: 3), "no score counts them")

        header.mutantsNotCovered?.append(uncovered("Sources/New.swift", line: 4))
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        await AssertThrowsError(try await report(resultsPath, "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(
            standardError.linesPassed.last,
            "  Sources/New.swift:4:9 RelationalOperatorReplacement: * → / (coverage left it out)"
        )
    }

    // Results whose header doesn't record the mutants of code no test ran, with coverage on, as an older SwiftMutator's
    // or a run of a test plan it made, would make a baseline file without them, against which each would be new: none
    // is written, and a comparison says new code no test ran isn't seen. With `skipCoverage` there are none to record.
    func test_resultsThatDontRecordTheMutantsOfCodeNoTestRan_writeNone_andSaySo() async throws {
        try write(ResultsHeader.make(skipCoverage: false), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath, "--write-baseline", baselinePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
        XCTAssertTrue(
            standardError.linesPassed.contains(
                "No baseline file was saved to \(baselinePath): the results, of an older SwiftMutator or of a test "
                    + "plan it made, don't record the mutants of code no test ran, and a baseline file holds a whole "
                    + "run's survivors."
            ),
            "\(standardError.linesPassed)"
        )

        XCTAssertTrue(BaselineFile(
            path: baselinePath,
            swiftMutator: "1.0.0",
            score: .init(killed: 1, scored: 3),
            scope: BaselineScope(header: ResultsHeader.make(skipCoverage: false)),
            survivors: []
        ).save(using: FileManager.default))
        try await report(resultsPath, "--baseline", baselinePath, "--max-new-survivors", "2")
        let unseen = "The results don't record the mutants of code no test ran, so new code no test ran isn't seen."
        XCTAssertTrue(
            standardError.linesPassed.contains { $0.hasSuffix(unseen) },
            "\(standardError.linesPassed)"
        )

        var recorded = ResultsHeader.make(skipCoverage: false)
        recorded.mutantsNotCovered = []
        try write(recorded, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try await report(resultsPath, "--write-baseline", baselinePath)
        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10])
    }

    // Each shard records those it holds, and the merge takes them all, each once by its key.
    func test_mergedShards_takeEveryShardsMutantsOfCodeNoTestRan() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        var one = shardHeader(1, mutantsDiscovered: 2)
        one.mutantsNotCovered = [uncovered("Sources/Zeta.swift", line: 30), uncovered("Sources/Alpha.swift", line: 8)]
        var two = shardHeader(2, mutantsDiscovered: 1)
        two.mutantsNotCovered = [uncovered("Sources/Zeta.swift", line: 30), uncovered("Sources/Zeta.swift", line: 40)]
        try write(one, zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(two, zeta10, ResultsEnd.make(), to: second)

        try await report(first, second, "--write-baseline", baselinePath)

        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(
            written.survivors.map { "\($0.mutant.path):\($0.mutant.line)" },
            [
                "Sources/Alpha.swift:8",
                "Sources/Zeta.swift:9",
                "Sources/Zeta.swift:10",
                "Sources/Zeta.swift:30",
                "Sources/Zeta.swift:40",
            ]
        )

        // A shard whose header doesn't record them, with coverage on, leaves them unknown for the merge.
        try FileManager.default.removeItem(atPath: baselinePath)
        var recorded = shardHeader(1, mutantsDiscovered: 2, skipCoverage: false)
        recorded.mutantsNotCovered = one.mutantsNotCovered
        try write(recorded, zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1, skipCoverage: false), zeta10, ResultsEnd.make(), to: second)
        try await report(first, second, "--write-baseline", baselinePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
    }

    // Saving it would destroy what the report is made from.
    func test_writeBaseline_atTheResultsFile_isRefused() async throws {
        try write(ResultsHeader.make(), zeta9, ResultsEnd.make(), to: resultsPath)

        await AssertThrowsError(try await report(resultsPath, "--write-baseline", resultsPath)) { error in
            XCTAssertTrue(
                "\(error)".contains(
                    "is the results file the report is made from: choose another --write-baseline path"
                ),
                "\(error)"
            )
        }
    }
}

private extension ReportBaselineTests {
    /// A mutant of code no test ran, at column 9 of `line` of `path`, which would replace `*` with `/`.
    func uncovered(_ path: String, line: Int) -> UncoveredMutant {
        UncoveredMutant(
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: 9, occurrence: 0),
            snapshot: .make(before: "*", after: "/")
        )
    }

    /// A baseline file at `baselinePath` of `ResultsHeader.make()`'s scope, recording `survivors`, and `score`.
    func writeBaseline(survivors: [MutantResult], score: BaselineFile.Score = .init(killed: 0, scored: 0)) throws {
        let file = BaselineFile(
            path: baselinePath,
            swiftMutator: "1.0.0",
            score: score,
            scope: scope,
            survivors: survivors.map {
                BaselineSurvivor(
                    mutant: $0.key,
                    outcome: .survived,
                    before: $0.snapshot.before,
                    after: $0.snapshot.after
                )
            }
        )
        XCTAssertTrue(file.save(using: FileManager.default))
    }

    /// The header of shard `index` of 2 of the 3 mutants: Alpha.swift:3 and Zeta.swift:9 in shard 1, Zeta.swift:10 in
    /// shard 2.
    func shardHeader(
        _ index: Int,
        mutantsDiscovered: Int,
        allKeysSHA256: String = "a11",
        skipCoverage: Bool = true
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
            skipCoverage: skipCoverage,
            shard: .make(
                index: index,
                count: 2,
                mutantsInAllShards: 3,
                mutantsPerShard: [2, 1],
                allKeysSHA256: allKeysSHA256
            )
        )
    }

    func report(_ arguments: String...) async throws {
        try await report(arguments: arguments)
    }

    func report(arguments: [String]) async throws {
        let command = try MuterCommand.parseAsRoot(["report"] + arguments)
        guard let report = command as? Report else {
            return XCTFail("Expected the report command, got \(command)")
        }
        try await report.run()
    }

    func write(_ records: any Encodable..., to path: String) throws {
        try write(records: records, to: path)
    }

    func write(records: [any Encodable], to path: String) throws {
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
