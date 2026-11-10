import ArgumentParser
@testable import muterCore
import XCTest

/// The verdict on a run's survivors against a baseline file's: what it says, and the status it exits with.
final class NewSurvivorsCheckTests: XCTestCase {
    private func key(_ line: Int, path: String = "Sources/X.swift") -> MutantKey {
        MutantKey(path: path, mutationOperatorId: .relationalBoundary, line: line, column: 17, occurrence: 0)
    }

    private func baseline(_ survivors: [MutantKey], version: String = "0.1.0") -> BaselineFile {
        BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: version,
            score: .init(killed: 0, scored: 0),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: survivors.map { BaselineSurvivor(mutant: $0, outcome: .survived, before: "<", after: "<=") }
        )
    }

    private func outcome(_ mutants: [(MutantKey, TestSuiteOutcome)], mutant: String? = nil) -> MutationTestOutcome {
        MutationTestOutcome(
            mutations: mutants.map { key, outcome in
                .make(testSuiteOutcome: outcome, snapshot: .make(before: "<", after: "<="), key: key)
            },
            mutant: mutant
        )
    }

    private func check(
        _ survivors: [MutantKey],
        against mutants: [(MutantKey, TestSuiteOutcome)],
        allowing allowed: Int = 0,
        version: String = "0.1.0",
        mutant: String? = nil,
        unless notChecked: NewSurvivorsCheck.NotChecked? = nil
    ) -> NewSurvivorsCheck {
        NewSurvivorsCheck(
            baseline: baseline(survivors),
            maxNewSurvivors: allowed,
            judging: outcome(mutants, mutant: mutant),
            version: version,
            unless: notChecked
        ) { _ in nil }
    }

    func test_noNewSurvivor_passes_sayingWhatStillSurvives_andWhatWasFixed() {
        let verdict = check([key(1), key(2), key(3, path: "Sources/Gone.swift")], against: [
            (key(1), .passed), (key(2), .failed),
        ])

        XCTAssertTrue(try XCTUnwrap(verdict.passed))
        XCTAssertNil(verdict.exitStatus)
        XCTAssertEqual(
            verdict.lines,
            [
                "No new survivors against the baseline file muter.baseline.yml: 1 still survive, 1 fixed, 1 not "
                    + "tested. 2 were matched without their line, as their files changed since they were tested, or "
                    + "can't be read.",
            ]
        )
    }

    func test_newSurvivors_beyondTheLimit_fail_andAreListed() {
        let verdict = check([key(1)], against: [(key(1), .passed), (key(5), .timeout), (key(9), .noCoverage)])

        XCTAssertFalse(try XCTUnwrap(verdict.passed))
        XCTAssertEqual(verdict.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(verdict.exitStatus?.rawValue, 2)
        XCTAssertEqual(verdict.lines, [
            "2 new survivors against the baseline file muter.baseline.yml, more than the 0 allowed: 1 still survive, "
                + "0 fixed. 1 was matched without its line, as its file changed since it was tested, or can't be read.",
            "  Sources/X.swift:5:17 RelationalBoundary: < → <=",
            "  Sources/X.swift:9:17 RelationalBoundary: < → <= (coverage left it out)",
        ])
    }

    // Code no test ran makes no mutant with coverage on, so a pull request that adds a function no test calls would add
    // no survivor: they count here, though no score counts them. One a test comes to run is fixed if the test kills it,
    // and still survives if not.
    func test_theMutantsOfCodeNoTestRan_countAsSurvivors() {
        var judged = outcome([(key(2), .failed), (key(3), .passed)])
        judged.uncoveredMutants = [key(1), key(7, path: "Sources/New.swift")].map {
            UncoveredMutant(key: $0, snapshot: .make(before: "<", after: "<="))
        }

        let verdict = NewSurvivorsCheck(
            baseline: BaselineFile(
                path: "muter.baseline.yml",
                swiftMutator: "0.1.0",
                score: .init(killed: 0, scored: 0),
                scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
                survivors: [key(1), key(2), key(3)].map {
                    BaselineSurvivor(mutant: $0, outcome: .notCovered, before: "<", after: "<=")
                }
            ),
            maxNewSurvivors: 0,
            judging: judged,
            version: "0.1.0"
        ) { _ in nil }

        XCTAssertFalse(try XCTUnwrap(verdict.passed))
        XCTAssertEqual(verdict.lines, [
            "1 new survivor against the baseline file muter.baseline.yml, more than the 0 allowed: 2 still survive, "
                + "1 fixed. 3 were matched without their line, as their files changed since they were tested, or "
                + "can't be read.",
            "  Sources/New.swift:7:17 RelationalBoundary: < → <= (coverage left it out)",
        ])
        let summary = RunSummary.NewSurvivors(verdict)
        XCTAssertEqual(summary.newMutants, ["Sources/New.swift:7:17 RelationalBoundary"])
        XCTAssertEqual(summary.newNotCovered, 1)
    }

    // With lines unknown, a survivor that changes what the entry's mutant changed is that mutant, before a kill at its
    // key: survivors pair first, so an identical twin that was killed counts as neither new nor fixed.
    func test_anIdenticalSurvivor_pairsBeforeAKillAtTheEntrysKey() {
        let verdict = check([key(1)], against: [(key(1), .failed), (key(5), .passed)])

        XCTAssertTrue(try XCTUnwrap(verdict.passed))
        guard case let .checked(comparison) = verdict.verdict else {
            XCTFail("\(verdict)")
            return
        }
        XCTAssertEqual(comparison.stillSurvive, 1)
        XCTAssertEqual(comparison.fixed, 0)
        XCTAssertEqual(comparison.newSurvivors, [])
    }

    func test_newSurvivors_withinTheLimit_pass_andAreListed() {
        let verdict = check([], against: [(key(5), .passed)], allowing: 1)

        XCTAssertTrue(try XCTUnwrap(verdict.passed))
        XCTAssertEqual(verdict.lines, [
            "1 new survivor against the baseline file muter.baseline.yml, within the 1 allowed: 0 still survive, 0 "
                + "fixed.",
            "  Sources/X.swift:5:17 RelationalBoundary: < → <=",
        ])
    }

    func test_atMost20NewSurvivors_areListed() {
        let verdict = check([], against: (1 ... 23).map { (key($0), .passed) })

        XCTAssertEqual(verdict.lines.count, 1 + 20 + 1)
        XCTAssertEqual(verdict.lines.last, "  …and 3 more")
    }

    func test_aOneMutantRun_isntChecked() {
        let verdict = check([], against: [(key(5), .passed)], mutant: "Sources/X.swift:5:17 RelationalBoundary")

        XCTAssertNil(verdict.passed)
        XCTAssertNil(verdict.exitStatus)
        XCTAssertEqual(
            verdict.line,
            "The survivors aren't compared with the baseline file muter.baseline.yml: one mutant's run (--mutant) "
                + "isn't the project's."
        )
    }

    func test_eachReasonNotToCheck_isSaid_butAnEarlyEnd() {
        let file = "The survivors aren't compared with the baseline file muter.baseline.yml"
        XCTAssertEqual(
            check([], against: [], unless: .stoppedOnAnError).line,
            "\(file): the run stopped on an error."
        )
        XCTAssertEqual(check([], against: [], unless: .lacksResults).line, "\(file): the merged report lacks results.")
        XCTAssertNil(check([], against: [], unless: .endedEarly).line)
        XCTAssertEqual(check([], against: [], unless: .endedEarly).lines, [])
    }

    // `report` of a sample's results doesn't know the mutants the sample left out, so an entry is paired only at its
    // own key: an entry for one of them could otherwise hide a new, identical survivor elsewhere in its file. A run
    // knows them, and pairs by the line.
    func test_resultsThatLeaveOutUnknownMutants_pairOnlyAtTheEntrysKey() {
        var sampled = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .passed, snapshot: .make(before: "<", after: "<="), key: key(5))],
            sample: SampleSelection(size: 1, seed: 7, mutantsSampledFrom: 4, mutantsSampled: 1)
        )
        XCTAssertTrue(sampled.leavesOutUnknownMutants)
        let fromAFile = NewSurvivorsCheck(
            baseline: baseline([key(1)]),
            maxNewSurvivors: 0,
            judging: sampled,
            version: "0.1.0"
        ) { _ in nil }
        XCTAssertFalse(try XCTUnwrap(fromAFile.passed))

        sampled.unselectedMutants = []
        XCTAssertFalse(sampled.leavesOutUnknownMutants)
        let fromTheRun = NewSurvivorsCheck(
            baseline: baseline([key(1)]),
            maxNewSurvivors: 0,
            judging: sampled,
            version: "0.1.0"
        ) { _ in nil }
        XCTAssertTrue(try XCTUnwrap(fromTheRun.passed))
    }

    // As `--fail-under` says it, of `report` of a run that didn't finish.
    func test_anUnfinishedRun_saysHowManyMutantsHaveResults() {
        let verdict = NewSurvivorsCheck(
            baseline: baseline([]),
            maxNewSurvivors: 0,
            judging: outcome([(key(5), .failed)]),
            version: "0.1.0",
            progress: .init(results: 1, discovered: 40)
        ) { _ in nil }

        XCTAssertEqual(
            verdict.line,
            "No new survivors against the baseline file muter.baseline.yml: 0 still survive, 0 fixed. Only 1 of 40 "
                + "mutants have results, as the run didn't finish."
        )
    }

    // New operators' mutants may show as new, so another version is noted, not refused.
    func test_anotherVersion_isNoted() {
        XCTAssertNil(check([], against: []).versionNotice)
        XCTAssertEqual(
            check([], against: [], version: "0.2.0").versionNotice,
            "The baseline file muter.baseline.yml was written by SwiftMutator 0.1.0, and these survivors by 0.2.0: a "
                + "new or changed operator's mutants may show as new survivors."
        )
    }

    // Results that don't record the mutants of code no test ran, as an older SwiftMutator's, can't show new ones, and
    // the baseline file's entries for such code are not tested: the line says so.
    func test_resultsThatDontRecordTheMutantsOfCodeNoTestRan_saySo() {
        var judged = outcome([])
        judged.uncoveredMutants = nil

        let verdict = NewSurvivorsCheck(
            baseline: baseline([key(1)]),
            maxNewSurvivors: 0,
            judging: judged,
            version: "0.1.0"
        ) { _ in nil }

        XCTAssertTrue(verdict.uncoveredMutantsUnknown)
        XCTAssertEqual(
            verdict.line,
            "No new survivors against the baseline file muter.baseline.yml: 0 still survive, 0 fixed, 1 not tested. "
                + "The results don't record the mutants of code no test ran, so new code no test ran isn't seen."
        )
        XCTAssertFalse(check([key(1)], against: []).uncoveredMutantsUnknown)
    }

    // A run prints the version's notice first, then the verdict with its emoji, then each new survivor.
    func test_theConsoleLines_markTheVerdict() {
        XCTAssertEqual(check([], against: [(key(5), .passed)], version: "0.2.0").consoleLines, [
            "⚠️ The baseline file muter.baseline.yml was written by SwiftMutator 0.1.0, and these survivors by 0.2.0: "
                + "a new or changed operator's mutants may show as new survivors.",
            "❌ 1 new survivor against the baseline file muter.baseline.yml, more than the 0 allowed: 0 still survive, "
                + "0 fixed.",
            "  Sources/X.swift:5:17 RelationalBoundary: < → <=",
        ])
        XCTAssertEqual(check([], against: []).consoleLines.first?.hasPrefix("✅ "), true)
        XCTAssertEqual(check([], against: [], mutant: "M").consoleLines.first?.hasPrefix("⚠️ "), true)
        XCTAssertEqual(check([], against: [], unless: .endedEarly).consoleLines, [])
    }

    // Any failed check exits 2, as #96 gives every failed gate.
    func test_theChecks_exit2_whenAnyFailed() {
        let failed = check([], against: [(key(5), .passed)])
        let passed = check([], against: [])
        let below = ScoreGate(failUnder: 80, judging: .make([.failed, .passed]))
        let meets = ScoreGate(failUnder: 50, judging: .make([.failed, .passed]))

        XCTAssertNil(RunChecks().exitStatus)
        XCTAssertTrue(RunChecks().isEmpty)
        XCTAssertEqual(RunChecks(newSurvivors: failed).exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(RunChecks(scoreGate: meets, newSurvivors: failed).exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(RunChecks(scoreGate: below, newSurvivors: passed).exitStatus, .scoreBelowThreshold)
        XCTAssertNil(RunChecks(scoreGate: meets, newSurvivors: passed).exitStatus)
    }

    func test_maxNewSurvivors_takesAWholeNumber() {
        XCTAssertEqual(NewSurvivorsCheck.allowed("0"), 0)
        XCTAssertEqual(NewSurvivorsCheck.allowed("12"), 12)
        for text in ["", "-1", "1.5", "1e2", " 3", "x"] {
            XCTAssertNil(NewSurvivorsCheck.allowed(text), text)
        }
    }

    // Recorded for scripts beside the score's gate, and left out without `--baseline`.
    func test_theSummary_recordsTheVerdict() throws {
        let verdict = check([key(1)], against: [(key(1), .failed), (key(5, path: "Sources/Y.swift"), .passed)])
        let summary = RunSummary(of: .make([.passed]), ended: .finished, report: nil, newSurvivors: verdict)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: summary.json) as? [String: AnyHashable])
        XCTAssertEqual(json["newSurvivors"] as? [String: AnyHashable], [
            "baseline": "muter.baseline.yml",
            "maxNewSurvivors": 0,
            "passed": false,
            "new": 1,
            "newMutants": ["Sources/Y.swift:5:17 RelationalBoundary"],
            "newNotCovered": 0,
            "stillSurvive": 0,
            "fixed": 1,
            "notTested": 0,
            "matchedWithoutLine": 1,
        ])
        let unchecked = RunSummary(
            of: .make([.passed]),
            ended: .finished,
            report: nil,
            newSurvivors: check([], against: [], unless: .endedEarly)
        )
        let notChecked = try XCTUnwrap(JSONSerialization.jsonObject(with: unchecked.json) as? [String: AnyHashable])
        XCTAssertEqual((notChecked["newSurvivors"] as? [String: AnyHashable])?["notChecked"] as? String, "endedEarly")
        XCTAssertNil((notChecked["newSurvivors"] as? [String: AnyHashable])?["passed"])
        let without = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RunSummary(of: .make([.passed]), ended: .finished, report: nil).json)
                as? [String: AnyHashable]
        )
        XCTAssertNil(without["newSurvivors"])
    }
}
