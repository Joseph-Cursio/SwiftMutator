@testable import muterCore
import XCTest

/// The verdict on the kills a run's score counts that its own evidence doesn't back: which are doubtful, what it says,
/// and the status it exits with.
final class DoubtfulKillsCheckTests: XCTestCase {
    private func key(_ line: Int) -> MutantKey {
        MutantKey(
            path: "Sources/X.swift",
            mutationOperatorId: .relationalBoundary,
            line: line,
            column: 17,
            occurrence: 0
        )
    }

    /// A mutant at `line` of Sources/X.swift that came out `outcome`, with nothing shown of whether its code ran.
    private func mutant(_ line: Int, _ outcome: TestSuiteOutcome) -> MutationTestOutcome.Mutation {
        MutationTestOutcome.Mutation.make(
            testSuiteOutcome: outcome,
            snapshot: .make(before: "<", after: "<="),
            key: key(line)
        )
    }

    /// A mutant at `line` of Sources/X.swift that came out `outcome`, its code shown running or not as `activated`
    /// says.
    private func mutant(
        _ line: Int,
        _ outcome: TestSuiteOutcome,
        activated: MutantActivation
    ) -> MutationTestOutcome.Mutation {
        var mutation = mutant(line, outcome)
        mutation.activated = activated
        return mutation
    }

    /// `withSuspectTests`' mutants, in which only suspect tests were recorded failing for the kills in files 7 to 12,
    /// the 7th to the 12th, with `change` made to each.
    private func suspectOnly(
        _ change: (Int, inout MutationTestOutcome.Mutation) -> Void = { _, _ in }
    ) -> MutationTestOutcome {
        let mutations = MutationTestOutcome.withSuspectTests.mutations.enumerated().map { index, mutation in
            var changed = mutation
            change(index, &changed)
            return changed
        }
        return .make(mutations: mutations)
    }

    // As `KillingTestSummary` counts them: those no rerun alone settled.
    func test_killsOnlySuspectTestsMade_thatNoRerunSettled_areDoubtful() throws {
        let outcome = suspectOnly()
        let verdict = DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome)

        let summary = try XCTUnwrap(KillingTestSummary(of: outcome.mutations))
        XCTAssertEqual(verdict.doubtfulKills.count, summary.suspectOnlyKillsNotTestedAlone)
        XCTAssertEqual(verdict.doubtfulKills.count, 6)
        XCTAssertTrue(verdict.doubtfulKills.allSatisfy { $0.suspectOnly && !$0.codeNeverRan })
        XCTAssertEqual(verdict.result, .failed)
        XCTAssertEqual(verdict.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(
            verdict.line,
            "6 doubtful kills, more than the 0 allowed: 6 kills only suspect tests made, which no rerun alone settled."
        )
        XCTAssertEqual(verdict.lines.count, 7)
        XCTAssertTrue(verdict.lines[1].hasPrefix("  Sources/File07.swift:3:3 "), verdict.lines[1])
        XCTAssertTrue(verdict.lines[1].hasSuffix(" (only suspect tests killed it)"), verdict.lines[1])
    }

    // A kill this run tested again alone that failed again is settled; one a reused run's rerun settled isn't this
    // run's evidence.
    func test_aKillTestedAgainAlone_isSettled_butNotOneReused() {
        let rerun = MutantResult.Rerun(because: MutantResult.Rerun.onlySuspectTestsFailed, workers: 1)
        let outcome = suspectOnly { index, mutation in
            if index == 6 { mutation.rerun = rerun }
        }
        XCTAssertEqual(DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome).doubtfulKills.count, 5)

        let reused = MutationTestOutcome.make(mutations: suspectOnly().mutations.enumerated().map { index, mutation in
            guard index == 6 else { return mutation }
            var copy = MutationTestOutcome.Mutation.make(
                testSuiteOutcome: mutation.testSuiteOutcome,
                point: mutation.point,
                killingTests: mutation.killingTests,
                reusedFrom: ReusedFrom(resultsFile: "/old/results.jsonl", session: 1, despiteChanges: false)
            )
            copy.rerun = rerun
            return copy
        })
        XCTAssertEqual(DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: reused).doubtfulKills.count, 6)
    }

    // As `unprovenKillWarning` counts them: a kill or a crash whose code didn't run; one whose code is not known to
    // have run isn't doubtful.
    func test_killsWhoseCodeNeverRan_areDoubtful() {
        let outcome = MutationTestOutcome.make(mutations: [
            mutant(1, .failed, activated: .didNotRun),
            mutant(2, .runtimeError, activated: .didNotRun),
            mutant(3, .failed),
            mutant(4, .failed, activated: .ran),
            mutant(5, .passed, activated: .didNotRun),
            mutant(6, .timeout, activated: .didNotRun),
        ])

        let verdict = DoubtfulKillsCheck(maxDoubtfulKills: 1, judging: outcome)

        XCTAssertEqual(verdict.result, .failed)
        XCTAssertEqual(verdict.lines, [
            "2 doubtful kills, more than the 1 allowed: 2 kills whose code never ran.",
            "  Sources/X.swift:1:17 RelationalBoundary: < → <= (its code never ran)",
            "  Sources/X.swift:2:17 RelationalBoundary: < → <= (its code never ran)",
        ])
        XCTAssertEqual(outcome.unprovenKillWarning?.hasPrefix("2 kills' code never ran"), true)
        XCTAssertEqual(DoubtfulKillsCheck(maxDoubtfulKills: 2, judging: outcome).result, .passed)
        XCTAssertEqual(
            DoubtfulKillsCheck(maxDoubtfulKills: 2, judging: outcome).line,
            "2 doubtful kills, within the 2 allowed: 2 kills whose code never ran."
        )
    }

    // A kill only suspect tests made whose code never ran is one doubtful kill.
    func test_aKillThatIsBoth_countsOnce() throws {
        let outcome = suspectOnly { index, mutation in
            if index == 6 { mutation.activated = .didNotRun }
        }

        let verdict = DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome)

        XCTAssertEqual(verdict.doubtfulKills.count, 6)
        XCTAssertEqual(
            verdict.line,
            "6 doubtful kills, more than the 0 allowed: 6 kills only suspect tests made, which no rerun alone settled, "
                + "and 1 kill whose code never ran. 1 of them is both."
        )
        XCTAssertTrue(
            verdict.lines[1].hasSuffix(" (only suspect tests killed it, and its code never ran)"),
            verdict.lines[1]
        )
        let summary = RunSummary.DoubtfulKills(verdict)
        XCTAssertEqual(summary.count, 6)
        XCTAssertEqual(summary.suspectOnly, 6)
        XCTAssertEqual(summary.codeNeverRan, 1)
    }

    func test_noDoubtfulKill_passes() {
        let verdict = DoubtfulKillsCheck(
            maxDoubtfulKills: 0,
            judging: .make(mutations: [mutant(1, .failed, activated: .ran), mutant(2, .passed)])
        )

        XCTAssertEqual(verdict.result, .passed)
        XCTAssertNil(verdict.exitStatus)
        XCTAssertEqual(verdict.lines, ["No doubtful kills."])
        XCTAssertEqual(verdict.consoleLines, ["✅ No doubtful kills."])
    }

    // It counts what was tested, so a run that tested only some mutants is checked too.
    func test_aLimitedRun_isChecked() {
        let mutations = [mutant(1, .failed, activated: .didNotRun)]
        let limited = [
            MutationTestOutcome(mutations: mutations, mutant: "Sources/X.swift:1:17 RelationalBoundary"),
            MutationTestOutcome(
                mutations: mutations,
                shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2))
            ),
            MutationTestOutcome(
                mutations: mutations,
                sample: SampleSelection(size: 1, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 1)
            ),
            MutationTestOutcome(mutations: mutations, since: .make(changedLines: true)),
        ]
        for outcome in limited {
            XCTAssertEqual(DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome).result, .failed)
        }
    }

    func test_aRunThatStopped_isNotChecked() {
        let outcome = MutationTestOutcome.make(mutations: [mutant(1, .failed, activated: .didNotRun)])

        let ended = DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome, unless: .endedEarly)
        XCTAssertEqual(ended.result, .notChecked)
        XCTAssertNil(ended.exitStatus)
        XCTAssertNil(ended.line)
        XCTAssertEqual(ended.consoleLines, [])
        XCTAssertEqual(
            DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome, unless: .stoppedOnAnError).consoleLines,
            ["⚠️ Doubtful kills aren't counted: the run stopped on an error."]
        )
        XCTAssertEqual(
            DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome, unless: .lacksResults).line,
            "Doubtful kills aren't counted: the merged report lacks results."
        )
    }

    func test_theLines_nameTheFirst20() {
        let outcome = MutationTestOutcome.make(mutations: (1 ... 25).map { mutant($0, .failed, activated: .didNotRun) })

        let lines = DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome).consoleLines

        XCTAssertEqual(lines.count, 22)
        XCTAssertEqual(lines.first, "❌ 25 doubtful kills, more than the 0 allowed: 25 kills whose code never ran.")
        XCTAssertEqual(lines[20], "  Sources/X.swift:20:17 RelationalBoundary: < → <= (its code never ran)")
        XCTAssertEqual(lines.last, "  …and 5 more")
    }

    func test_maxDoubtfulKills_takesAWholeNumber() {
        XCTAssertEqual(DoubtfulKillsCheck.allowed("0"), 0)
        XCTAssertEqual(DoubtfulKillsCheck.allowed("12"), 12)
        for refused in ["-1", "1.5", "", "x"] {
            XCTAssertNil(DoubtfulKillsCheck.allowed(refused), refused)
        }
    }

    func test_theSummary_recordsTheVerdict() throws {
        let outcome = MutationTestOutcome.make(mutations: [mutant(1, .failed, activated: .didNotRun)])
        let summary = RunSummary(
            of: outcome,
            ended: .finished,
            report: nil,
            doubtfulKills: DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome)
        )

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? [String: Any])
        let recorded = try XCTUnwrap(json["doubtfulKills"] as? [String: Any])
        XCTAssertEqual(
            Set(recorded.keys),
            ["maxDoubtfulKills", "count", "suspectOnly", "codeNeverRan", "mutants", "passed"]
        )
        XCTAssertEqual(recorded["mutants"] as? [String], ["Sources/X.swift:1:17 RelationalBoundary"])
        XCTAssertEqual(recorded["passed"] as? Bool, false)
        XCTAssertNil(json["scoreDrop"])

        let unchecked = RunSummary.DoubtfulKills(
            DoubtfulKillsCheck(maxDoubtfulKills: 0, judging: outcome, unless: .endedEarly)
        )
        XCTAssertEqual(unchecked.notChecked, .endedEarly)
        XCTAssertEqual(unchecked.passed, .notChecked)
        XCTAssertEqual(unchecked.count, 0)
    }

    func test_anyFailedCheck_exits2() {
        let failed = DoubtfulKillsCheck(maxDoubtfulKills: 0, verdict: .checked([
            .init(
                mutant: "Sources/X.swift:1:17 RelationalBoundary",
                before: "<",
                after: "<=",
                suspectOnly: false,
                codeNeverRan: true
            ),
        ]))
        let passed = DoubtfulKillsCheck(maxDoubtfulKills: 0, verdict: .checked([]))
        let drop = ScoreDropCheck(
            baseline: "b.yml",
            maxScoreDrop: 2,
            baselineScore: .init(killed: 9, scored: 10),
            killed: 1,
            scored: 10,
            verdict: .failed
        )

        XCTAssertEqual(RunChecks(doubtfulKills: failed).exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(RunChecks(scoreDrop: drop).exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(RunChecks(scoreDrop: drop, doubtfulKills: passed).exitStatus, .scoreBelowThreshold)
        XCTAssertNil(RunChecks(doubtfulKills: passed).exitStatus)
        XCTAssertFalse(RunChecks(doubtfulKills: passed).isEmpty)
        XCTAssertFalse(RunChecks(scoreDrop: drop).isEmpty)
    }
}
