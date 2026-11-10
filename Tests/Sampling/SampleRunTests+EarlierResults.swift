@testable import muterCore
import Rainbow
import TestingExtensions
import XCTest

extension SampleRunTests {
    // A results file's report says what its header recorded.
    func test_aResultsFilesReport_saysWhatTheSampleTested() {
        let header = ResultsHeader.make(
            sample: SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2)
        )

        let outcome = MutationTestOutcome(
            records: [MutantResult](),
            under: header,
            testDuration: 0,
            shards: nil,
            sampleIsCutShort: false,
            controlRuns: []
        )

        XCTAssertEqual(outcome.sample, header.sample)
    }

    // A file has a margin once every mutant its last session set out to test has a result, a resumed one's
    // included.
    func test_aResultsFilesSample_isCutShort_whileAMutantHasNoResult() throws {
        let sample = SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2)
        let first = MutantResult.make(line: 3, outcome: .failed)
        let second = MutantResult.make(session: 2, line: 9, outcome: .passed)
        let stopped = try RecordedResults.read(resultsFileData([
            ResultsHeader.make(mutantsDiscovered: 2, mutantsToTest: 2, sample: sample),
            first,
            ResultsEnd.make(reason: .interrupted, detail: "SIGINT", recorded: 1),
        ]), path: "/logs/results.jsonl")
        let resumed = try RecordedResults.read(resultsFileData([
            ResultsHeader.make(mutantsDiscovered: 2, mutantsToTest: 2, sample: sample),
            first,
            ResultsEnd.make(reason: .interrupted, detail: "SIGINT", recorded: 1),
            ResultsHeader.make(
                formatVersion: ResultsCoding.resumedFormatVersion,
                session: 2,
                mutantsDiscovered: 2,
                mutantsToTest: 1,
                sample: sample
            ),
            second,
            ResultsEnd.make(session: 2, recorded: 1),
        ]), path: "/logs/results.jsonl")

        XCTAssertTrue(stopped.mutationTestOutcome().sampleIsCutShort)
        XCTAssertNil(MuterTestReport(from: stopped.mutationTestOutcome()).sample?.marginOfError)
        XCTAssertFalse(resumed.mutationTestOutcome().sampleIsCutShort)
        XCTAssertNotNil(MuterTestReport(from: resumed.mutationTestOutcome()).sample?.marginOfError)
    }

    // After a change, new mutants can rank before some the sample took: they are still discovered, only not sampled.
    func test_aResultsMutantTheSampleNoLongerTakes_isCountedApart() {
        let kept = MutantResult.make(path: "Sources/Sum.swift", line: 3, outcome: .failed, fileSHA256: "ab12")
        let outside = MutantResult.make(path: "Sources/Sum.swift", line: 9, outcome: .passed)
        let gone = MutantResult.make(path: "Sources/Gone.swift", line: 1, outcome: .passed)

        let plan = ResumePlan.make(
            keys: [kept.key],
            snapshots: [kept.snapshot],
            recorded: [kept.key: kept, outside.key: outside, gone.key: gone],
            fileHashes: ["Sources/Sum.swift": "ab12"],
            leftOut: [outside.key]
        )

        XCTAssertEqual(plan.noLongerDiscovered, 1)
        XCTAssertEqual(plan.outsideTheSample, 1)
        XCTAssertEqual(Set(plan.retired), [outside.key, gone.key])
    }

    func test_aResume_saysHowManyResultsTheSampleNoLongerTakes_ratherThanWarning() {
        Logger().resumePlanned(summary(outsideTheSample: 3))
        Logger().resumePlanned(summary(outsideTheSample: 1))

        XCTAssertEqual(printer.linesPassed.filter { $0.contains("earlier result") }, [
            "ℹ️ 3 earlier results no longer count, as the sample no longer takes their mutants.",
            "ℹ️ 1 earlier result no longer counts, as the sample no longer takes its mutant.",
        ])
        XCTAssertFalse(printer.linesPassed.contains { $0.hasPrefix("⚠️") }, "\(printer.linesPassed)")
    }

    // A reuse of another sample says why in a sentence of its own.
    func test_aReuseOfAnotherSample_saysWhy_ratherThanCounting() {
        var summary = summary(outsideTheSample: 3, selectionChange: "That run tested another sample.")
        summary.sampleChanged = true

        Logger().resumePlanned(summary)

        XCTAssertEqual(printer.linesPassed.filter { $0.contains("sample") }, ["ℹ️ That run tested another sample."])
    }

    // A reuse of another shard of the same sample explains the shard, not the mutants the sample no longer takes.
    func test_aReuseOfAnotherShardOfTheSameSample_stillCountsTheResultsOutsideIt() {
        Logger().resumePlanned(summary(outsideTheSample: 3, selectionChange: "That run tested only shard 1 of 4."))

        XCTAssertEqual(printer.linesPassed.filter { $0.hasPrefix("ℹ️") }, [
            "ℹ️ That run tested only shard 1 of 4.",
            "ℹ️ 3 earlier results no longer count, as the sample no longer takes their mutants.",
        ])
    }

    // A partial sample's count moves as new mutants rank into it, or into another shard of it: not a change in what
    // discovery found.
    func test_aSamplesCountThatMoved_isNotWarnedOf() {
        // 4 kept and 3 to test, where the last session discovered 5: a sample's, then a run's without one.
        Logger().resumePlanned(summary(outsideTheSample: 1, toTest: 3, sampleIsPartial: true))
        Logger().resumePlanned(summary(outsideTheSample: 0, toTest: 3))

        XCTAssertEqual(printer.linesPassed.filter { $0.hasPrefix("⚠️") }, [
            "⚠️ This session discovers 7 mutants, and the last one discovered 5.",
        ])
    }

    // A sample that reuses a whole run's results keeps only those it takes: not all of the file's.
    func test_aReuseWithNothingLeftToTest_saysHowManyStillHold_notAll() {
        Logger().resumePlanned(self.summary(outsideTheSample: 671, toTest: 0, sampleIsPartial: true))

        XCTAssertEqual(
            printer.linesPassed.first,
            "♻️ Resuming the run in \("/logs/results.jsonl".bold): 4 results still hold, so nothing is left to test."
        )
    }

    // What discovery leaves out reaches the state, which a resume or a reuse then tells from mutants no longer
    // discovered.
    func test_discovery_recordsTheKeysTheSampleLeavesOut() async throws {
        try prepare()
        let wholeRun = try await keys(discovering: nil)
        XCTAssertTrue(state.keysLeftOutOfTheSample.isEmpty)
        let sample = Sample(size: 2, seed: 1_234, seedIsChosen: false)
        let sampled = try await keys(discovering: sample)
        state.runOptions = .make(sample: sample)

        state.apply(try await DiscoverMutationPoints().run(with: state))

        XCTAssertEqual(state.keysLeftOutOfTheSample, Set(wholeRun).subtracting(sampled))
        XCTAssertFalse(state.keysLeftOutOfTheSample.isEmpty)
    }

    // A whole run's results reused by a sample: most of them aren't of its mutants, which is no loss.
    func test_aReuseOfAnotherSample_saysWhy_ratherThanWarning() {
        let sample = Sample(size: 500, seed: 1_234, seedIsChosen: false)

        XCTAssertNil(ResumeSummary.sampleChange(from: nil, to: nil))
        XCTAssertNil(ResumeSummary.sampleChange(from: sample, to: Sample(size: 500, seed: 1_234, seedIsChosen: true)))
        XCTAssertEqual(
            ResumeSummary.sampleChange(from: nil, to: sample),
            "This run tests only a sample of 500 (seed 1234), so no earlier result of a mutant outside it is reused."
        )
        XCTAssertEqual(
            ResumeSummary.sampleChange(from: sample, to: nil),
            "That run tested only a sample of 500 (seed 1234), so this run's other mutants have no earlier result."
        )
        XCTAssertEqual(
            ResumeSummary.sampleChange(from: sample, to: Sample(size: 500, seed: 7, seedIsChosen: true)),
            "That run tested a sample of 500 (seed 1234), and this one tests a sample of 500 (seed 7), so only the "
                + "mutants in both have an earlier result."
        )
        XCTAssertEqual(
            ResumeSummary.selectionChange(from: (nil, nil, nil), to: (nil, nil, sample)),
            "This run tests only a sample of 500 (seed 1234), so no earlier result of a mutant outside it is reused."
        )
    }
}
