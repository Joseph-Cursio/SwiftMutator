@testable import muterCore
import TestingExtensions
import XCTest

/// The verdict on a score against `--fail-under` or `failUnder`: which score, which runs, and what is said.
final class ScoreGateTests: MuterTestCase {
    private let shard = ShardScope(indices: [1], count: 2, mutantsInAllShards: 4)

    /// `killed` mutants killed of `scored`, with `buildErrors` more, judged against `failUnder`.
    private func gate(
        killed: Int,
        of scored: Int,
        buildErrors: Int = 0,
        failUnder: Double,
        progress: ScoreGate.Progress? = nil
    ) -> ScoreGate {
        let outcomes = Array(repeating: TestSuiteOutcome.failed, count: killed)
            + Array(repeating: .passed, count: scored - killed)
            + Array(repeating: .buildError, count: buildErrors)
        return ScoreGate(failUnder: failUnder, judging: .make(outcomes), progress: progress)
    }

    // Exactly: a score equal to the threshold passes, as does one above it by less than the whole percent the reports
    // show.
    func test_theExactScoreIsCompared_andEqualPasses() {
        XCTAssertEqual(gate(killed: 4, of: 5, failUnder: 80).verdict, .passed)
        XCTAssertEqual(gate(killed: 398, of: 500, failUnder: 79.5).verdict, .passed)
        let headline = Array(repeating: TestSuiteOutcome.failed, count: 398) + Array(repeating: .passed, count: 102)
        XCTAssertEqual(mutationScore(from: headline), 79)
        let below = gate(killed: 4, of: 5, failUnder: 80.5)
        XCTAssertEqual(below.verdict, .failed)
        XCTAssertEqual(below.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(below.exitStatus?.rawValue, 2)
        XCTAssertNil(gate(killed: 4, of: 5, failUnder: 80).exitStatus)
    }

    // 29 / 50 * 100 is 57.99999999999999, which would fail a threshold the score meets.
    func test_aScoreThatIsAWholePercent_meetsIt() {
        XCTAssertEqual(gate(killed: 29, of: 50, failUnder: 58).verdict, .passed)
        XCTAssertEqual(gate(killed: 29, of: 50, failUnder: 58).score, 58)
        XCTAssertEqual(gate(killed: 29, of: 100, failUnder: 29).verdict, .passed)
    }

    // Build errors aren't scored, as in the headline.
    func test_buildErrors_areLeftOut() {
        let judged = gate(killed: 1, of: 2, buildErrors: 3, failUnder: 50)
        XCTAssertEqual(judged.verdict, .passed)
        XCTAssertEqual(judged.score, 50)
    }

    // Nothing measured falls short, so a change that touches no Swift code doesn't fail. But with mutants that were all
    // build errors, as when none compiles, nothing was measured that there was to measure, and the run can't pass.
    func test_nothingToScore_passes_andNothingButBuildErrors_fails() {
        let none = ScoreGate(failUnder: 80, judging: .make([]))
        XCTAssertEqual(none.verdict, .nothingScored(tested: 0))
        XCTAssertNil(none.exitStatus)
        XCTAssertNil(none.score)
        XCTAssertTrue(none.passed)
        XCTAssertEqual(none.line, "No mutant was tested, so no score falls short of the required 80%.")
        let buildErrors = gate(killed: 0, of: 0, buildErrors: 2, failUnder: 80)
        XCTAssertEqual(buildErrors.verdict, .nothingScored(tested: 2))
        XCTAssertFalse(buildErrors.passed)
        XCTAssertEqual(buildErrors.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(buildErrors.line, "Every mutant was a build error, so nothing shows the required 80% is met.")
    }

    // Those without one may yet compile, and be tested.
    func test_aRunNotFinished_saysItsResultsWereBuildErrors() {
        let unfinished = ScoreGate(
            failUnder: 10,
            judging: .make([.buildError, .buildError]),
            progress: .init(results: 2, discovered: 9)
        )

        XCTAssertFalse(unfinished.passed)
        XCTAssertEqual(
            unfinished.line,
            "Every mutant with a result was a build error, so nothing shows the required 10% is met. "
                + "Only 2 of 9 mutants have results, as the run didn't finish."
        )
    }

    // A run killed or stopped after its header, or still under way: mutants are known, and none has a result. A CI job
    // shaped like `run || true; report --fail-under 80` must not go green on it.
    func test_aRunNotFinishedWithNoResults_fails() {
        let noResults = ScoreGate(failUnder: 80, judging: .make([]), progress: .init(results: 0, discovered: 4))

        XCTAssertEqual(noResults.verdict, .nothingScored(tested: 0))
        XCTAssertFalse(noResults.passed)
        XCTAssertEqual(noResults.exitStatus, .scoreBelowThreshold)
        XCTAssertNil(noResults.score)
        XCTAssertEqual(
            noResults.line,
            "No mutant was tested, so nothing shows the required 80% is met. "
                + "Only 0 of 4 mutants have results, as the run didn't finish."
        )
    }

    // A threshold of 0 otherwise can't fail, but nothing was measured.
    func test_nothingButBuildErrors_failsEvenAThresholdOfZero() {
        XCTAssertEqual(gate(killed: 0, of: 0, buildErrors: 2, failUnder: 0).exitStatus, .scoreBelowThreshold)
    }

    // They may compile, so taking them out can't help a run pass: 2 of 2 tested would be 100%.
    func test_mutantsTakenOutWithOthers_countAsNotKilled_inTheScoreChecked() {
        var withOthers = MutationTestOutcome.Mutation.make(testSuiteOutcome: .buildError)
        withOthers.leftOutWithOthers = true
        let outcome = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .failed), .make(testSuiteOutcome: .failed)]
                + Array(repeating: withOthers, count: 6)
                + [.make(testSuiteOutcome: .buildError)]
        )

        let gate = ScoreGate(failUnder: 80, judging: outcome)

        XCTAssertEqual(gate.verdict, .failed)
        XCTAssertEqual(gate.score, 25)
        XCTAssertEqual(gate.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(
            gate.line,
            "Mutation score 25.0% is below the required 80%. 6 mutants went out of the build with others, and count "
                + "here as not killed. 1 mutant was a build error, and isn't scored."
        )
        XCTAssertEqual(MuterTestReport(from: outcome).globalMutationScore, 100, "the headline score stays as it is")
    }

    // Nothing was tested, so there is no score at all, whatever the threshold.
    func test_onlyMutantsTakenOutWithOthers_areNothingScored_evenAtAThresholdOfZero() {
        var withOthers = MutationTestOutcome.Mutation.make(testSuiteOutcome: .buildError)
        withOthers.leftOutWithOthers = true

        let gate = ScoreGate(failUnder: 0, judging: MutationTestOutcome(mutations: [withOthers, withOthers]))

        XCTAssertEqual(gate.verdict, .nothingScored(tested: 2))
        XCTAssertNil(gate.score)
        XCTAssertFalse(gate.passed)
        XCTAssertEqual(gate.line, "Every mutant was a build error, so nothing shows the required 0% is met.")
    }

    // Leaving mutants out raises the score, so a line about the score says some are left out.
    func test_theLine_saysHowManyAreLeftOut() {
        XCTAssertEqual(
            gate(killed: 1, of: 2, buildErrors: 3, failUnder: 50).line,
            "Mutation score 50.0% meets the required 50%. 3 mutants were build errors, and aren't scored."
        )
        XCTAssertEqual(
            gate(killed: 1, of: 2, buildErrors: 1, failUnder: 80).line,
            "Mutation score 50.0% is below the required 80%. 1 mutant was a build error, and isn't scored."
        )
    }

    // One mutant's score isn't the project's, and one shard's isn't the whole run's, however low.
    func test_oneMutant_andAShard_areNotChecked() {
        let oneMutant = ScoreGate(failUnder: 80, judging: .make([.passed], mutant: "Foo.swift:3:9 ROR"))
        XCTAssertEqual(oneMutant.verdict, .notChecked(.oneMutant))
        XCTAssertNil(oneMutant.exitStatus)
        XCTAssertNil(oneMutant.passed)
        XCTAssertEqual(
            oneMutant.line,
            "The required 80% isn't checked: one mutant's score (--mutant) isn't the project's."
        )
        let aShard = ScoreGate(failUnder: 80, judging: .make([.passed], shards: shard))
        XCTAssertEqual(aShard.verdict, .notChecked(.shard))
        XCTAssertNil(aShard.exitStatus)
        XCTAssertEqual(
            aShard.line,
            "The required 80% isn't checked: a shard's score isn't the whole run's. Check the merged report instead: "
                + "swift-mutator report --fail-under 80 <each shard's results file>"
        )
        // A shard whose others hold no mutant is the whole run.
        XCTAssertEqual(ScoreGate(failUnder: 80, judging: .make([.passed])).verdict, .failed)
    }

    // The reason it's given wins over the rest.
    func test_aReasonNotToCheck_wins() {
        let outcome = MutationTestOutcome.make([.passed], mutant: "Foo.swift:3:9 ROR")
        for reason in [ScoreGate.NotChecked.endedEarly, .stoppedOnAnError, .lacksResults] {
            let judged = ScoreGate(failUnder: 80, judging: outcome, unless: reason)
            XCTAssertEqual(judged.verdict, .notChecked(reason))
            XCTAssertNil(judged.exitStatus)
        }
        XCTAssertNil(ScoreGate(failUnder: 80, judging: outcome, unless: .endedEarly).line)
        XCTAssertEqual(
            ScoreGate(failUnder: 80, judging: outcome, unless: .stoppedOnAnError).line,
            "The required 80% isn't checked: the run stopped on an error."
        )
        XCTAssertEqual(
            ScoreGate(failUnder: 72.5, judging: outcome, unless: .lacksResults).line,
            "The required 72.5% isn't checked: the merged report lacks results."
        )
    }

    // Truncated to the threshold's decimals, at least one, so it never shows on the wrong side of the threshold.
    func test_theScoreIsShown_onTheSideOfTheThresholdItIs() {
        XCTAssertEqual(
            gate(killed: 5, of: 7, failUnder: 80).line,
            "Mutation score 71.4% is below the required 80%."
        )
        XCTAssertEqual(
            gate(killed: 799, of: 1_000, failUnder: 80).line,
            "Mutation score 79.9% is below the required 80%."
        )
        XCTAssertEqual(
            gate(killed: 1_999, of: 2_500, failUnder: 80).line,
            "Mutation score 79.9% is below the required 80%."
        )
        XCTAssertEqual(
            gate(killed: 1_999, of: 2_500, failUnder: 79.95).line,
            "Mutation score 79.96% meets the required 79.95%."
        )
        XCTAssertEqual(
            gate(killed: 29, of: 40, failUnder: 72.5).line,
            "Mutation score 72.5% meets the required 72.5%."
        )
        XCTAssertEqual(
            gate(killed: 1, of: 3, failUnder: 33.3).line,
            "Mutation score 33.3% meets the required 33.3%."
        )
        XCTAssertEqual(gate(killed: 3, of: 3, failUnder: 100).line, "Mutation score 100.0% meets the required 100%.")
        XCTAssertEqual(gate(killed: 0, of: 3, failUnder: 0).line, "Mutation score 0.0% meets the required 0%.")
    }

    // For `report` of a run that didn't finish.
    func test_aRunThatDidntFinish_saysHowManyHaveResults() {
        XCTAssertEqual(
            gate(killed: 1, of: 2, failUnder: 80, progress: .init(results: 2, discovered: 5)).line,
            "Mutation score 50.0% is below the required 80%. Only 2 of 5 mutants have results, as the run didn't "
                + "finish."
        )
    }

    // Plain decimals from 0 to 100, as `--fail-under` takes them.
    func test_percent_takesPlainDecimalsFrom0To100() {
        XCTAssertEqual(ScoreGate.percent("80"), 80)
        XCTAssertEqual(ScoreGate.percent("72.5"), 72.5)
        XCTAssertEqual(ScoreGate.percent("0"), 0)
        XCTAssertEqual(ScoreGate.percent("100"), 100)
        XCTAssertEqual(ScoreGate.percent("100.0"), 100)
        XCTAssertEqual(ScoreGate.percent("0.000001"), 0.000001)
        XCTAssertEqual(ScoreGate.percent("33.333333"), 33.333333)
        for text in ["-1", "100.1", "nan", "inf", "eighty", "", "1e2", "0x50", "+80", "80.", ".5", " 80"]
            + ["0.0000001", "0.0000004", "0.0000006", "33.3333333", "80.0000000"] {
            XCTAssertNil(ScoreGate.percent(text), text)
        }
    }

    // Every threshold `percent(_:)` takes is shown as it was written, so the verdict states it, and the --shard hint's
    // command takes it again.
    func test_everyThresholdTaken_isShownAsWritten() throws {
        for text in ["0.000001", "0.000004", "0.00001", "0.0001", "0.5", "33.333333", "99.999999", "100", "0"] {
            let percent = try XCTUnwrap(ScoreGate.percent(text), text)
            XCTAssertEqual(ScoreGate.shown(percent), text)
            XCTAssertEqual(ScoreGate.percent(ScoreGate.shown(percent)), percent, text)
        }
        // One `percent(_:)` refuses is still shown as it is, as a refusal shows it.
        XCTAssertEqual(ScoreGate.shown(0.0000001), "0.0000001")
        XCTAssertEqual(ScoreGate.shown(0.0000004), "0.0000004")
    }

    // A threshold with the most decimals still shows a passing score at or above it, and a failing one below it.
    func test_aThresholdWithTheMostDecimals_isShownBesideAScoreWithAsMany() {
        XCTAssertEqual(
            gate(killed: 1, of: 3, failUnder: 33.333333).line,
            "Mutation score 33.333333% meets the required 33.333333%."
        )
        XCTAssertEqual(
            gate(killed: 1, of: 3, failUnder: 33.333334).line,
            "Mutation score 33.333333% is below the required 33.333334%."
        )
        XCTAssertEqual(
            gate(killed: 0, of: 3, failUnder: 0.000001).line,
            "Mutation score 0.000000% is below the required 0.000001%."
        )
        XCTAssertEqual(
            ScoreGate(failUnder: 0.000001, judging: .make([.passed], shards: shard)).line,
            "The required 0.000001% isn't checked: a shard's score isn't the whole run's. Check the merged report "
                + "instead: swift-mutator report --fail-under 0.000001 <each shard's results file>"
        )
    }

    func test_shown_writesAPercentAsItIsWritten() {
        XCTAssertEqual(ScoreGate.shown(80), "80")
        XCTAssertEqual(ScoreGate.shown(72.5), "72.5")
        XCTAssertEqual(ScoreGate.shown(0.00001), "0.00001")
        XCTAssertEqual(ScoreGate.shown(.infinity), "inf")
    }

    // ✅ when it passes, ❌ when it fails, ⚠️ when it isn't checked, and nothing for a run that ended early.
    func test_theLogger_printsTheVerdict_withItsEmoji() {
        let logger = Logger()

        logger.scoreGateChecked(gate(killed: 4, of: 5, failUnder: 80))
        logger.scoreGateChecked(ScoreGate(failUnder: 80, judging: .make([])))
        logger.scoreGateChecked(gate(killed: 1, of: 5, failUnder: 80))
        logger.scoreGateChecked(ScoreGate(failUnder: 80, judging: .make([.passed], shards: shard)))
        logger.scoreGateChecked(ScoreGate(failUnder: 80, judging: .make([.passed]), unless: .endedEarly))

        XCTAssertEqual(printer.linesPassed.map { String($0.prefix(2)) }, ["✅ ", "✅ ", "❌ ", "⚠️ "])
        XCTAssertEqual(printer.linesPassed[2], "❌ Mutation score 20.0% is below the required 80%.")
    }
}
