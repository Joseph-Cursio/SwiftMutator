import ArgumentParser
@testable import muterCore
import XCTest

/// The verdict on a run's score against a baseline file's: the drop compared exactly, what it says, which results it
/// doesn't compare, and the status it exits with.
final class ScoreDropCheckTests: XCTestCase {
    private func baseline(killed: Int, of scored: Int) -> BaselineFile {
        BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: "0.1.0",
            score: .init(killed: killed, scored: scored),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: []
        )
    }

    private func check(
        _ killed: Int,
        of scored: Int,
        against recorded: (killed: Int, scored: Int),
        allowing limit: Double = 2
    ) -> ScoreDropCheck {
        ScoreDropCheck(
            baseline: baseline(killed: recorded.killed, of: recorded.scored),
            maxScoreDrop: limit,
            killed: killed,
            scored: scored
        )
    }

    /// An outcome that killed `killed` of `scored` mutants, each in a file of its own.
    private func outcome(killed: Int, of scored: Int) -> MutationTestOutcome {
        .make(Array(repeating: .failed, count: killed) + Array(repeating: .passed, count: scored - killed))
    }

    func test_aDropEqualToTheLimit_passes() {
        let verdict = check(78, of: 100, against: (80, 100))

        XCTAssertEqual(verdict.verdict, .passed)
        XCTAssertEqual(verdict.passed, true)
        XCTAssertNil(verdict.exitStatus)
        XCTAssertEqual(
            verdict.line,
            "Mutation score 78.0% is 2.0 points below the baseline file muter.baseline.yml's 80.0%, within the 2 "
                + "allowed."
        )
        XCTAssertEqual(verdict.consoleLines, ["✅ " + (verdict.line ?? "")])
    }

    // Compared exactly from the counts: 0.0000001 points past the limit fails, and shows past it.
    func test_aDropJustPastTheLimit_fails_andShowsPastIt() {
        let verdict = check(779_999_999, of: 1_000_000_000, against: (80, 100))

        XCTAssertEqual(verdict.verdict, .failed)
        XCTAssertEqual(verdict.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(verdict.exitStatus?.rawValue, 2)
        XCTAssertEqual(
            verdict.line,
            "Mutation score 77.9% is 2.1 points below the baseline file muter.baseline.yml's 80.0%, more than the 2 "
                + "allowed."
        )
        XCTAssertEqual(verdict.consoleLines, ["❌ " + (verdict.line ?? "")])

        let finer = check(779_999_999, of: 1_000_000_000, against: (80, 100), allowing: 2.000001)
        XCTAssertEqual(finer.verdict, .passed)
        XCTAssertEqual(
            finer.line,
            "Mutation score 77.999999% is 2.000001 points below the baseline file muter.baseline.yml's 80.000000%, "
                + "within the 2.000001 allowed."
        )
    }

    // As many decimals as the limit has: the scores truncated, as the reports show their whole percent, and the drop as
    // the difference of the two shown, so the line adds up, and a drop within the limit never shows past it.
    func test_theScoresAndTheDrop_showAsManyDecimalsAsTheLimit() {
        let verdict = check(66, of: 100, against: (2, 3), allowing: 0.25)

        XCTAssertEqual(verdict.passed, false)
        XCTAssertEqual(
            verdict.line,
            "Mutation score 66.00% is 0.66 points below the baseline file muter.baseline.yml's 66.66%, more than the "
                + "0.25 allowed."
        )
        // 0.666… is within 0.7, and shows within it.
        XCTAssertEqual(
            check(66, of: 100, against: (2, 3), allowing: 0.7).line,
            "Mutation score 66.0% is 0.6 points below the baseline file muter.baseline.yml's 66.6%, within the 0.7 "
                + "allowed."
        )
    }

    // 82.09% and 80% show as 82.0% and 80.0% with the limit's one decimal, 2.0 apart, within the 2 allowed, though the
    // drop is past it: one more decimal shows it past it.
    func test_aDropPastTheLimit_thatShowsWithinIt_showsMoreDecimals() {
        let verdict = check(80, of: 100, against: (8_209, 10_000))

        XCTAssertEqual(verdict.passed, false)
        XCTAssertEqual(
            verdict.line,
            "Mutation score 80.00% is 2.09 points below the baseline file muter.baseline.yml's 82.09%, more than the 2 "
                + "allowed."
        )
        // A drop past a limit of 0 that the shown scores hide, however little.
        XCTAssertEqual(
            check(1, of: 3, against: (33_334, 100_000), allowing: 0).line,
            "Mutation score 33.333% is 0.001 points below the baseline file muter.baseline.yml's 33.334%, more than "
                + "the 0 allowed."
        )
        // Within the limit, the shown scores may be the same.
        XCTAssertEqual(
            check(1, of: 3, against: (33_334, 100_000)).line,
            "Mutation score 33.3% is less than 0.1 points below the baseline file muter.baseline.yml's 33.3%, within "
                + "the 2 allowed."
        )
        // A rise shows as the difference of the two shown too: 84.0 - 82.0, though the exact rise is 1.91.
        XCTAssertEqual(
            check(84, of: 100, against: (8_209, 10_000)).line,
            "Mutation score 84.0% is 2.0 points above the baseline file muter.baseline.yml's 82.0%."
        )
    }

    // summary.json's drop is worked out from the counts, as the verdict is: one equal to the limit is the limit, never
    // the difference of two inexact scores, which here is 2.0000000000000036 or 2.0000000000000018.
    func test_theDrop_isExact_soADropEqualToTheLimit_isTheLimit() throws {
        for (run, recorded) in [((47, 150), (1, 3)), ((176, 1_200), (300, 1_800))] {
            let verdict = check(run.0, of: run.1, against: recorded)
            XCTAssertEqual(verdict.passed, true)
            XCTAssertEqual(verdict.drop, 2)
            let summary = RunSummary(of: .make([.passed]), ended: .finished, report: nil, scoreDrop: verdict)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? [String: Any])
            let recordedDrop = try XCTUnwrap(json["scoreDrop"] as? [String: Any])
            XCTAssertEqual(recordedDrop["drop"] as? Double, 2)
        }
        XCTAssertEqual(check(1, of: 10, against: (2, 10), allowing: 0.1).drop, 10)
        XCTAssertEqual(check(9, of: 10, against: (1, 10)).drop, -80)
        XCTAssertEqual(check(899, of: 1_000, against: (9, 10), allowing: 0.1).drop, 0.1)
    }

    func test_aRise_orTheSameScore_passes() {
        XCTAssertEqual(
            check(84, of: 100, against: (80, 100)).line,
            "Mutation score 84.0% is 4.0 points above the baseline file muter.baseline.yml's 80.0%."
        )
        let same = check(160, of: 200, against: (80, 100), allowing: 0)
        XCTAssertEqual(same.passed, true)
        XCTAssertEqual(same.line, "Mutation score 80.0% is the same as the baseline file muter.baseline.yml's.")
        XCTAssertEqual(
            check(33_334, of: 100_000, against: (1, 3), allowing: 0).line,
            "Mutation score 33.3% is less than 0.1 points above the baseline file muter.baseline.yml's 33.3%."
        )
        XCTAssertEqual(check(84, of: 100, against: (80, 100), allowing: 0).passed, true)
    }

    // As `--fail-under` counts it: a mutant taken out of the build with others may compile, so counts as not killed.
    func test_theRunsScore_isTheOneTheGateChecks() {
        var buildError = MutationTestOutcome.Mutation.make(testSuiteOutcome: .buildError)
        buildError.leftOutWithOthers = true
        let outcome = MutationTestOutcome(mutations: outcome(killed: 3, of: 4).mutations + [buildError])

        let verdict = ScoreDropCheck(baseline: baseline(killed: 3, of: 4), maxScoreDrop: 2, judging: outcome)

        XCTAssertEqual(verdict.killed, 3)
        XCTAssertEqual(verdict.scored, 5)
        XCTAssertEqual(
            verdict.line,
            "Mutation score 60.0% is 15.0 points below the baseline file muter.baseline.yml's 75.0%, more than the 2 "
                + "allowed."
        )
        XCTAssertEqual(verdict.score, 60)
        XCTAssertEqual(verdict.baselineScorePercent, 75)
        XCTAssertEqual(verdict.drop, 15)
    }

    // Only a whole project's score compares with the file's.
    func test_resultsThatArentTheWholeProjects_areNotChecked_andSayWhy() {
        let tested = outcome(killed: 1, of: 2)
        var filesToMutate = tested
        filesToMutate.filesToMutate = ["Sources/X.swift"]
        let cases: [(MutationTestOutcome, ScoreGate.Progress?, ScoreDropCheck.NotChecked, String)] = [
            (
                .make([.failed], mutant: "Sources/X.swift:1:1 RelationalBoundary"),
                nil,
                .oneMutant,
                "one mutant's score (--mutant) isn't the project's."
            ),
            (
                .make([.failed], shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2))),
                nil,
                .shard,
                "a shard's score isn't the whole run's. Compare the merged report instead: swift-mutator report "
                    + "--baseline muter.baseline.yml --max-score-drop 2 <each shard's results file>"
            ),
            (
                MutationTestOutcome(
                    mutations: tested.mutations,
                    sample: SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2)
                ),
                nil,
                .sample,
                "a sample's score (--sample) isn't the whole project's."
            ),
            (
                MutationTestOutcome(mutations: tested.mutations, since: .make(changedLines: true)),
                nil,
                .since,
                "the score of the code --since chose isn't the whole project's."
            ),
            (
                MutationTestOutcome(mutations: tested.mutations, since: .make()),
                nil,
                .since,
                "the score of the code --since chose isn't the whole project's."
            ),
            (
                filesToMutate,
                nil,
                .filesToMutate,
                "the score of the files --files-to-mutate chose isn't the whole project's."
            ),
            (
                tested,
                ScoreGate.Progress(results: 2, discovered: 10),
                .unfinished,
                "only 2 of 10 mutants have results, as the run didn't finish."
            ),
            (
                MutationTestOutcome(mutations: tested.mutations, sampleIsCutShort: true),
                nil,
                .unfinished,
                "the run didn't test every mutant it discovered."
            ),
            (.make([.buildError]), nil, .nothingScored, "no mutant was scored."),
            (.make([]), nil, .nothingScored, "no mutant was scored."),
        ]
        for (judged, progress, reason, why) in cases {
            let verdict = ScoreDropCheck(
                baseline: baseline(killed: 1, of: 2),
                maxScoreDrop: 2,
                judging: judged,
                progress: progress
            )
            XCTAssertEqual(verdict.verdict, .notChecked(reason))
            XCTAssertNil(verdict.passed)
            XCTAssertNil(verdict.exitStatus)
            XCTAssertNil(verdict.score)
            XCTAssertNil(verdict.drop)
            let line = "The score isn't compared with the baseline file muter.baseline.yml's: \(why)"
            XCTAssertEqual(verdict.line, line)
            XCTAssertEqual(verdict.consoleLines, ["⚠️ " + line])
        }

        let nothingRecorded = ScoreDropCheck(baseline: baseline(killed: 0, of: 0), maxScoreDrop: 2, judging: tested)
        XCTAssertEqual(
            nothingRecorded.line,
            "The score isn't compared with the baseline file muter.baseline.yml's: the baseline file records no "
                + "mutant scored."
        )
    }

    // A run that stopped says why itself; `report` says a stopped run's and a merge that lacks results aren't checked.
    func test_aRunThatStopped_isNotChecked() {
        let tested = outcome(killed: 1, of: 2)
        let file = baseline(killed: 1, of: 2)

        let ended = ScoreDropCheck(baseline: file, maxScoreDrop: 2, judging: tested, unless: .endedEarly)
        XCTAssertNil(ended.line)
        XCTAssertEqual(ended.consoleLines, [])
        XCTAssertNil(ended.exitStatus)
        XCTAssertEqual(
            ScoreDropCheck(baseline: file, maxScoreDrop: 2, judging: tested, unless: .stoppedOnAnError).line,
            "The score isn't compared with the baseline file muter.baseline.yml's: the run stopped on an error."
        )
        XCTAssertEqual(
            ScoreDropCheck(baseline: file, maxScoreDrop: 2, judging: tested, unless: .lacksResults).line,
            "The score isn't compared with the baseline file muter.baseline.yml's: the merged report lacks results."
        )
    }

    // As `--fail-under`'s percent.
    func test_maxScoreDrop_takesAPlainNumberOfPoints() {
        XCTAssertEqual(ScoreDropCheck.points("2"), 2)
        XCTAssertEqual(ScoreDropCheck.points("0"), 0)
        XCTAssertEqual(ScoreDropCheck.points("0.000001"), 0.000001)
        XCTAssertEqual(ScoreDropCheck.points("100"), 100)
        for refused in ["-1", "100.5", "1e2", "0x2", "0.0000001", "", "two"] {
            XCTAssertNil(ScoreDropCheck.points(refused), refused)
        }
    }

    func test_theSummary_recordsTheVerdict_andLeavesItOutWithoutTheFlag() throws {
        let verdict = check(78, of: 100, against: (82, 100))
        let summary = RunSummary(of: .make([.passed]), ended: .finished, report: nil, scoreDrop: verdict)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? [String: Any])
        let recorded = try XCTUnwrap(json["scoreDrop"] as? [String: Any])
        XCTAssertEqual(
            Set(recorded.keys),
            ["baseline", "maxScoreDrop", "baselineScore", "score", "drop", "passed"]
        )
        XCTAssertEqual(recorded["baseline"] as? String, "muter.baseline.yml")
        XCTAssertEqual(recorded["maxScoreDrop"] as? Double, 2)
        XCTAssertEqual(recorded["baselineScore"] as? Double, 82)
        XCTAssertEqual(recorded["score"] as? Double, 78)
        XCTAssertEqual(recorded["drop"] as? Double, 4)
        XCTAssertEqual(recorded["passed"] as? Bool, false)

        let unchecked = RunSummary(
            of: .make([.passed]),
            ended: .finished,
            report: nil,
            scoreDrop: ScoreDropCheck(
                baseline: baseline(killed: 1, of: 2),
                maxScoreDrop: 2,
                judging: .make([.failed], shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2)))
            )
        )
        XCTAssertEqual(unchecked.scoreDrop?.notChecked, .shard)
        XCTAssertNil(unchecked.scoreDrop?.passed)
        XCTAssertNil(unchecked.scoreDrop?.score)
        let plain = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RunSummary(of: .make([.passed]), ended: .finished, report: nil).json)
                as? [String: Any]
        )
        XCTAssertNil(plain["scoreDrop"])
        XCTAssertNil(plain["doubtfulKills"])
    }
}
