@testable import muterCore
import XCTest

/// The end of a run with a `failUnder`: the verdict on its score, said last, kept for the run's exit status, and
/// recorded in its summary.
final class MutationTestObserverScoreGateTests: MuterTestCase {
    private var options = Run.Options.make()

    private lazy var sut = MutationTestObserver(runOptions: options)

    override func setUp() {
        super.setUp()

        fileManager.currentDirectoryPathToReturn = "/"
    }

    private var summary: RunSummary? {
        try? JSONDecoder().decode(RunSummary.self, from: Data((writeFile.contentPassed ?? "").utf8))
    }

    private let resultsFileKept = "💾 Each mutant's result is in \("/logs/results.jsonl".bold)"

    // After where each result is, so it is the run's last line, which a CI log ends with.
    func test_aScoreBelowTheThreshold_isSaidLast_andRecorded() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingFinished(.make([.failed, .passed], failUnder: 80)))

        XCTAssertEqual(printer.linesPassed.suffix(2), [
            resultsFileKept,
            "❌ Mutation score 50.0% is below the required 80%.",
        ])
        XCTAssertEqual(sut.scoreGate?.verdict, .failed)
        XCTAssertEqual(sut.scoreGate?.exitStatus, .scoreBelowThreshold)
        XCTAssertEqual(summary?.gate, RunSummary.Gate(try XCTUnwrap(sut.scoreGate)))
        XCTAssertEqual(summary?.gate?.failUnder, 80)
        XCTAssertEqual(summary?.gate?.score, 50)
        XCTAssertEqual(summary?.gate?.passed, false)
        XCTAssertNil(summary?.gate?.notChecked)
    }

    func test_aScoreThatMeetsTheThreshold_isSaidLast() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingFinished(.make([.failed, .runtimeError], failUnder: 80)))

        XCTAssertEqual(printer.linesPassed.last, "✅ Mutation score 100.0% meets the required 80%.")
        XCTAssertEqual(sut.scoreGate?.verdict, .passed)
        XCTAssertNil(sut.scoreGate?.exitStatus)
        XCTAssertEqual(summary?.gate?.passed, true)
    }

    func test_withoutAThreshold_nothingIsSaid_orRecorded() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingFinished(.make([.passed])))

        XCTAssertEqual(printer.linesPassed.last, resultsFileKept)
        XCTAssertNil(sut.scoreGate)
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.gate)
    }

    // Said once, after its block: one mutant's score isn't the project's.
    func test_aOneMutantRun_saysTheThresholdIsntChecked() throws {
        options = .make(mutant: MutantReference(path: "Bar.swift", line: 12, column: 9))
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.oneMutantTested(.make()))
        runEvents.send(.mutationTestingFinished(.make([.passed], failUnder: 80, mutant: "Bar.swift:12:9")))

        XCTAssertEqual(printer.linesPassed.suffix(2), [
            resultsFileKept,
            "⚠️ The required 80% isn't checked: one mutant's score (--mutant) isn't the project's.",
        ])
        XCTAssertNil(sut.scoreGate?.exitStatus)
        XCTAssertEqual(summary?.gate?.notChecked, .oneMutant)
        XCTAssertNil(summary?.gate?.passed)
        XCTAssertNil(summary?.gate?.score)
    }

    // The merged report is the whole run's, which the line says how to check.
    func test_aShardsRun_pointsAtTheMergedReport() throws {
        try sut.start()
        let shard = ShardScope(indices: [1], count: 2, mutantsInAllShards: 4)

        runEvents.send(.mutationTestingFinished(MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .passed)],
            shards: shard,
            failUnder: 80
        )))

        XCTAssertEqual(
            printer.linesPassed.last,
            "⚠️ The required 80% isn't checked: a shard's score isn't the whole run's. Check the merged report "
                + "instead: swift-mutator report --fail-under 80 <each shard's results file>"
        )
        XCTAssertNil(sut.scoreGate?.exitStatus)
        XCTAssertEqual(summary?.gate?.notChecked, .shard)
    }

    // The run's end says why it stopped, and it exits for that; the summary records that the threshold wasn't checked,
    // without the partial score, which isn't the project's.
    func test_anEarlyEnd_saysNothingOfTheThreshold_andRecordsItUnchecked() throws {
        try sut.start()
        runEvents.send(.resultsFileCreated(path: "/logs/results.jsonl"))

        runEvents.send(.mutationTestingEndedEarly(EarlyEnd(
            reason: .aborted,
            detail: "tooManyBuildErrors",
            outcome: .make([.passed], failUnder: 80),
            discovered: 4,
            reused: 0
        )))

        XCTAssertFalse(
            (printer.linesPassed + standardError.linesPassed).contains { $0.contains("required") },
            "\(printer.linesPassed + standardError.linesPassed)"
        )
        XCTAssertNil(sut.scoreGate)
        XCTAssertEqual(summary?.ended, .aborted)
        XCTAssertEqual(summary?.gate?.notChecked, .endedEarly)
        XCTAssertEqual(summary?.gate?.failUnder, 80)
        XCTAssertNil(summary?.gate?.score)
        XCTAssertNil(summary?.gate?.passed)
    }
}
