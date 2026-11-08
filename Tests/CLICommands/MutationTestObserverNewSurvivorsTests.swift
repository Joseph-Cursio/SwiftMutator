@testable import muterCore
import XCTest

/// The end of a run with `--baseline` and `--write-baseline`: the checks made before any report, which the Markdown
/// report shows, then the reports, the baseline file and the summary, and the verdicts said last.
final class MutationTestObserverNewSurvivorsTests: MuterTestCase {
    private var options = Run.Options.make(
        reportFormat: .markdown,
        reportURL: URL(fileURLWithPath: "/out/report.md"),
        failUnder: 80,
        baseline: "muter.baseline.yml",
        writeBaseline: "/out/muter.baseline.yml"
    )

    private lazy var sut = MutationTestObserver(runOptions: options)

    private let resultsFileKept = "💾 Each mutant's result is in \("/logs/results.jsonl".bold)"

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/"
    }

    private var summary: RunSummary? {
        try? JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
    }

    private func key(_ line: Int) -> MutantKey {
        MutantKey(
            path: "Sources/X.swift",
            mutationOperatorId: .relationalBoundary,
            line: line,
            column: 17,
            occurrence: 0
        )
    }

    /// A run with a survivor at line 1, which the baseline file records, a new one at line 5, and a kill, against a
    /// baseline file SwiftMutator `version` wrote.
    private func outcome(baselineVersion version: String = muterCore.version) -> MutationTestOutcome {
        var outcome = MutationTestOutcome(
            mutations: [(1, TestSuiteOutcome.passed), (3, .failed), (5, .passed)].map { line, outcome in
                .make(testSuiteOutcome: outcome, snapshot: .make(before: "<", after: "<="), key: key(line))
            },
            failUnder: 80
        )
        outcome.baseline = BaselineFile(
            path: "muter.baseline.yml",
            swiftMutator: version,
            score: .init(killed: 1, scored: 2),
            scope: BaselineScope(operators: [], skipCoverage: false, configuration: .init()),
            survivors: [BaselineSurvivor(mutant: key(1), outcome: .survived, before: "<", after: "<=")]
        )
        outcome.baselineScope = BaselineScope(
            operators: ["RelationalBoundary"],
            skipCoverage: false,
            configuration: .init()
        )
        return outcome
    }

    func test_theChecks_areMadeBeforeTheReports_andSaidLast() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingFinished(outcome()))

        let report = String(decoding: try XCTUnwrap(fileManager.createdFiles["/out/report.md"]), as: UTF8.self)
        XCTAssertTrue(report.contains("### Checks"), report)
        XCTAssertTrue(report.contains("❌ Mutation score 33.3% is below the required 80%."), report)
        XCTAssertTrue(
            report.contains("❌ 1 new survivor against the baseline file muter.baseline.yml, more than the 0 allowed"),
            report
        )
        XCTAssertEqual(printer.linesPassed.suffix(5), [
            "📌 Baseline file saved: \("/out/muter.baseline.yml".bold)",
            resultsFileKept,
            "❌ Mutation score 33.3% is below the required 80%.",
            "❌ 1 new survivor against the baseline file muter.baseline.yml, more than the 0 allowed: 1 still survive, "
                + "0 fixed. 1 was matched without its line, as its file changed since it was tested, or can't be read.",
            "  Sources/X.swift:5:17 RelationalBoundary: < → <=",
        ])
        XCTAssertEqual(sut.checks.newSurvivors?.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(sut.checks.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(summary?.newSurvivors?.new, 1)
        XCTAssertEqual(summary?.newSurvivors?.newMutants, ["Sources/X.swift:5:17 RelationalBoundary"])
        XCTAssertEqual(summary?.gate?.passed, false)
    }

    // In the order fail-under, new survivors, score drop, doubtful kills, last; the reports show them all.
    func test_theScoreDrop_andTheDoubtfulKills_areCheckedToo_andSaidLast() throws {
        try sut.start()
        var finished = outcome()
        finished.maxScoreDrop = 2
        finished.maxDoubtfulKills = 0

        runEvents.send(.mutationTestingFinished(finished))

        let scoreDrop = "Mutation score 33.3% is 16.7 points below the baseline file muter.baseline.yml's 50.0%, more "
            + "than the 2 allowed."
        XCTAssertEqual(printer.linesPassed.suffix(4), [
            "❌ 1 new survivor against the baseline file muter.baseline.yml, more than the 0 allowed: 1 still survive, "
                + "0 fixed. 1 was matched without its line, as its file changed since it was tested, or can't be read.",
            "  Sources/X.swift:5:17 RelationalBoundary: < → <=",
            "❌ " + scoreDrop,
            "✅ No doubtful kills.",
        ])
        let report = String(decoding: try XCTUnwrap(fileManager.createdFiles["/out/report.md"]), as: UTF8.self)
        XCTAssertTrue(report.contains("❌ " + MarkdownText.plain(scoreDrop)), report)
        XCTAssertTrue(report.contains("✅ No doubtful kills."), report)
        XCTAssertEqual(sut.checks.scoreDrop?.passed, false)
        XCTAssertEqual(sut.checks.doubtfulKills?.passed, true)
        XCTAssertEqual(sut.checks.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(summary?.scoreDrop?.passed, false)
        XCTAssertEqual(summary?.scoreDrop?.baselineScore, 50)
        XCTAssertEqual(summary?.doubtfulKills?.count, 0)
        XCTAssertEqual(summary?.doubtfulKills?.passed, true)
    }

    // Doubtful kills need no baseline file; a failed check exits 2 on its own.
    func test_doubtfulKills_withoutABaselineFile_failTheRun() throws {
        options = .make(maxDoubtfulKills: 0)
        try sut.start()
        var doubtful = MutationTestOutcome.Mutation.make(
            testSuiteOutcome: .failed,
            snapshot: .make(before: "<", after: "<="),
            key: key(3)
        )
        doubtful.activated = false
        var finished = MutationTestOutcome(mutations: [doubtful])
        finished.maxDoubtfulKills = 0

        runEvents.send(.mutationTestingFinished(finished))

        XCTAssertEqual(printer.linesPassed.suffix(2), [
            "❌ 1 doubtful kill, more than the 0 allowed: 1 kill whose code never ran.",
            "  Sources/X.swift:3:17 RelationalBoundary: < → <= (its code never ran)",
        ])
        XCTAssertNil(sut.checks.scoreGate)
        XCTAssertNil(sut.checks.newSurvivors)
        XCTAssertNil(sut.checks.scoreDrop)
        XCTAssertEqual(sut.checks.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(summary?.doubtfulKills?.mutants, ["Sources/X.swift:3:17 RelationalBoundary"])
        XCTAssertNil(summary?.scoreDrop)
    }

    // A run that stopped says why itself: the summary records the checks weren't made, and nothing is said of them.
    func test_anEarlyEnd_checksNeitherTheScoreDrop_norTheDoubtfulKills() throws {
        try sut.start()
        var stopped = outcome()
        stopped.maxScoreDrop = 2
        stopped.maxDoubtfulKills = 0

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd(
            reason: .interrupted,
            detail: "SIGINT",
            outcome: stopped,
            discovered: 4,
            reused: 0
        )))

        XCTAssertFalse(
            (printer.linesPassed + standardError.linesPassed).contains {
                $0.contains("doubtful") || $0.contains("points below")
            },
            "\(printer.linesPassed + standardError.linesPassed)"
        )
        XCTAssertEqual(summary?.scoreDrop?.notChecked, .endedEarly)
        XCTAssertEqual(summary?.doubtfulKills?.notChecked, .endedEarly)
        XCTAssertEqual(sut.checks, RunChecks())
    }

    // The reports first, then the baseline file, then the summary.
    func test_theBaselineFile_isSavedAfterTheReports_withTheRunsSurvivors() throws {
        try sut.start()

        runEvents.send(.mutationTestingFinished(outcome()))

        let written = fileManager.paths.filter { ["/out/report.md", "/out/muter.baseline.yml"].contains($0) }
        XCTAssertEqual(written, ["/out/report.md", "/out/muter.baseline.yml"])
        let text = String(decoding: try XCTUnwrap(fileManager.createdFiles["/out/muter.baseline.yml"]), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(BaselineFile.introduction), text)
        XCTAssertTrue(text.contains("- mutant: Sources/X.swift:1:17 RelationalBoundary"), text)
        XCTAssertTrue(text.contains("- mutant: Sources/X.swift:5:17 RelationalBoundary"), text)
        XCTAssertFalse(text.contains("Sources/X.swift:3:17"), text)
        XCTAssertTrue(text.contains("score:\n  killed: 1\n  scored: 3\n"), text)
    }

    func test_aBaselineFileThatCantBeSaved_isOnlyAWarning() throws {
        fileManager.createFileToReturn = false
        options = .make(writeBaseline: "/out/muter.baseline.yml")
        try sut.start()

        runEvents.send(.mutationTestingFinished(outcome()))

        XCTAssertTrue(
            printer.linesPassed.contains("⚠️ Could not save the baseline file to /out/muter.baseline.yml"),
            "\(printer.linesPassed)"
        )
    }

    // New operators' mutants may show as new: a line before the verdict says so.
    func test_aBaselineFileOfAnotherVersion_isNoted_beforeTheVerdict() throws {
        options = .make(baseline: "muter.baseline.yml")
        try sut.start()

        runEvents.send(.mutationTestingFinished(outcome(baselineVersion: "0.0.9")))

        // After the score's verdict, before the survivors' and the new survivor's line.
        XCTAssertEqual(
            printer.linesPassed.suffix(3).first,
            "⚠️ The baseline file muter.baseline.yml was written by SwiftMutator 0.0.9, and these survivors by "
                + "\(muterCore.version): a new or changed operator's mutants may show as new survivors."
        )
    }

    // One mutant's run isn't the project's: said, and not failed.
    func test_aOneMutantRun_saysTheSurvivorsArentCompared() throws {
        options = .make(baseline: "muter.baseline.yml", mutant: MutantReference(path: "X.swift", line: 5, column: 17))
        try sut.start()
        var oneMutant = outcome()
        oneMutant = MutationTestOutcome(
            mutations: oneMutant.mutations,
            mutant: "Sources/X.swift:5:17 RelationalBoundary"
        )
        oneMutant.baseline = outcome().baseline

        runEvents.send(.oneMutantTested(.make()))
        runEvents.send(.mutationTestingFinished(oneMutant))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ The survivors aren't compared with the baseline file muter.baseline.yml: one mutant's run (--mutant) "
                + "isn't the project's."
        )
        XCTAssertNil(sut.checks.exitStatus)
        XCTAssertEqual(summary?.newSurvivors?.notChecked, .oneMutant)
    }

    // The run's end says why it stopped, and it exits for that; it saves no baseline file, and says why.
    func test_anEarlyEnd_comparesNothing_andSavesNoBaselineFile() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd(
            reason: .aborted,
            detail: "tooManyBuildErrors",
            outcome: outcome(),
            discovered: 4,
            reused: 0
        )))

        XCTAssertNil(fileManager.createdFiles["/out/muter.baseline.yml"])
        XCTAssertTrue(
            standardError.linesPassed.contains(
                "⚠️ No baseline file was saved to /out/muter.baseline.yml: the run stopped before it finished, and a "
                    + "baseline file holds a whole run's survivors."
            ),
            "\(standardError.linesPassed)"
        )
        XCTAssertFalse(
            (printer.linesPassed + standardError.linesPassed).contains { $0.contains("new survivor") },
            "\(printer.linesPassed + standardError.linesPassed)"
        )
        XCTAssertEqual(sut.checks, RunChecks())
        XCTAssertEqual(summary?.newSurvivors?.notChecked, .endedEarly)
        XCTAssertNil(summary?.newSurvivors?.passed)
    }

    // Without the flags, nothing is compared or saved, and the summary has no such key.
    func test_withoutTheFlags_nothingIsComparedOrSaved() throws {
        options = .make()
        try sut.start()
        var plain = outcome()
        plain.baseline = nil

        runEvents.send(.mutationTestingFinished(plain))

        XCTAssertNil(sut.checks.newSurvivors)
        XCTAssertNil(summary?.newSurvivors)
        XCTAssertFalse(fileManager.paths.contains { $0.hasSuffix(".yml") })
    }
}
