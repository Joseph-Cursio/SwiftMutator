import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportBaselineTests {
    // After the survivors' verdict: the score fell from 2 of 3 to 1 of 3, past the 2 points allowed.
    func test_aScoreDropPastTheLimit_exits2_andIsSaidAfterTheSurvivors() async throws {
        try write(ResultsHeader.make(), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try writeBaseline(survivors: [zeta9, zeta10], score: .init(killed: 2, scored: 3))
        let summaryPath = "\(directory)/summary.json"

        await AssertThrowsError(
            try report(
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
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: AnyHashable])
        let verdict = try XCTUnwrap(json["scoreDrop"] as? [String: AnyHashable], saved)
        XCTAssertEqual(verdict["passed"] as? Bool, false)
        XCTAssertEqual(verdict["maxScoreDrop"] as? Double, 2)

        try report(resultsPath, "--baseline", baselinePath, "--max-score-drop", "40")
        XCTAssertEqual(
            standardError.linesPassed.last?.hasSuffix("within the 40 allowed."),
            true,
            "\(standardError.linesPassed)"
        )
    }

    // Its score is of only the mutants it reached, so it isn't the whole project's.
    func test_anUnfinishedRun_doesntCompareTheScore() throws {
        let end = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        try write(ResultsHeader.make(mutantsDiscovered: 10), zeta9, alpha3, end, to: resultsPath)
        try writeBaseline(survivors: [zeta9], score: .init(killed: 9, scored: 10))

        try report(resultsPath, "--baseline", baselinePath, "--max-score-drop", "2")

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

        try report(first, second, "--baseline", baselinePath, "--max-score-drop", "0")
        XCTAssertEqual(
            standardError.linesPassed.last,
            "Mutation score 33.3% is the same as the baseline file \(baselinePath)'s."
        )

        await AssertThrowsError(try report(first, "--baseline", baselinePath, "--max-score-drop", "0")) { error in
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

        await AssertThrowsError(try report(resultsPath, "--max-doubtful-kills", "0")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "1 doubtful kill, more than the 0 allowed: 1 kill whose code never ran.",
            "  Sources/Alpha.swift:3:22 RelationalOperatorReplacement: > → < (its code never ran)",
        ])

        try report(resultsPath, "--max-doubtful-kills", "1")
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

        await AssertThrowsError(try report(arguments: [resultsPath] + flags)) { error in
            XCTAssertEqual(error as? ExitCode, .abortedMidRun)
        }
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "The score isn't compared with the baseline file \(baselinePath)'s: the run stopped on an error.",
            "Doubtful kills aren't counted: the run stopped on an error.",
        ])

        let stopped = ResultsStopped.make(step: .baseline, reason: .failed, detail: "baselineTestFailed")
        try write(stopped, to: resultsPath)
        await AssertThrowsError(try report(arguments: [resultsPath] + flags))
        XCTAssertEqual(standardError.linesPassed.suffix(2), [
            "The score isn't compared with the baseline file \(baselinePath)'s: the run stopped before its first "
                + "mutant.",
            "Doubtful kills aren't counted: the run stopped before its first mutant.",
        ])
    }

    // Each shard split its own discovery, so a mutant one discovered may fall to a shard whose run didn't discover it,
    // and have no result: the merge isn't known to be a whole run, so its score isn't compared, as no baseline file is
    // written from it. Here it would fall 66.7 points below the file's.
    func test_mergedShards_thatDiscoveredDifferentMutants_dontCompareTheScore() throws {
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

        try report(first, second, "--baseline", baselinePath, "--max-score-drop", "2")

        XCTAssertEqual(
            standardError.linesPassed.last,
            "The score isn't compared with the baseline file \(baselinePath)'s: the shards' runs didn't discover the "
                + "same mutants, so some may have no result."
        )
        let summaryPath = "\(directory)/summary.json"
        try report(
            first, second, "--baseline", baselinePath, "--max-score-drop", "2", "--summary", summaryPath
        )
        let saved = try String(contentsOfFile: summaryPath, encoding: .utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: AnyHashable])
        let verdict = try XCTUnwrap(json["scoreDrop"] as? [String: AnyHashable], saved)
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

        try report(resultsPath, "--max-doubtful-kills", "0")
        XCTAssertEqual(
            standardError.linesPassed.last,
            "Doubtful kills aren't counted: only 2 of 10 mutants have results, as the run didn't finish. --resume "
                + "tests the rest, then the kills only suspect tests made again alone."
        )

        try write(ResultsHeader.make(mutantsDiscovered: 2), zeta9, neverRan, end, to: resultsPath)
        await AssertThrowsError(try report(resultsPath, "--max-doubtful-kills", "0")) { error in
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

        try report(first, second, "--max-doubtful-kills", "0")
        XCTAssertEqual(standardError.linesPassed.last, "No doubtful kills.")

        try write(
            records: [ResultsHeader.make(mutantsDiscovered: 12, mutantsToTest: 12)] + kills(1) + kills(2)
                + [ResultsEnd.make()],
            to: resultsPath
        )
        await AssertThrowsError(try report(resultsPath, "--max-doubtful-kills", "0")) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertTrue(
            standardError.linesPassed.contains {
                $0.hasPrefix("12 doubtful kills, more than the 0 allowed: 12 kills only suspect tests made")
            },
            "\(standardError.linesPassed)"
        )
    }
}
