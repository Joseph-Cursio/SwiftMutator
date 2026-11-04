@testable import muterCore
import Rainbow
import TestingExtensions
import XCTest

/// What a `--sample` run discovers, and what it says: on the console, in its reports, and when it reuses an earlier
/// run's results.
final class SampleRunTests: MuterTestCase {
    private let state = MutationTestState()

    // Line 2 `<`, with two mutants, lines 8 and 9 statements RemoveSideEffects removes, line 13 `==`: five mutants.
    private let source = """
    func check(index: Int, items: [Int]) -> Bool {
        guard index <
            items.count - 1 else { return false }
        return true
    }

    func save(index: Int) {
        _ = record(index)
        _ = record(index + 1)
    }

    func other(a: Int) -> Bool {
        return a == 3
    }

    """

    override func setUp() {
        super.setUp()
        state.mutationOperatorList = .allOperators
        prepareCode.sourceCodeToReturn = {
            muterCore.sourceCode(fromFileAt: $0).map { (source: $0, changes: .null) }
        }
    }

    func test_aSample_keepsSomeOfTheMutants_eachWithItsKeyInTheWholeRun() async throws {
        try prepare()
        let wholeRun = try await keys(discovering: nil)

        let sampled = try await keys(discovering: Sample(size: 2, seed: 1234, seedIsChosen: false))

        XCTAssertEqual(sampled.count, 2)
        XCTAssertEqual(sampled, wholeRun.filter(Set(sampled).contains))
        let chosen = try await keys(discovering: Sample(size: 2, seed: 1234, seedIsChosen: true))
        XCTAssertEqual(chosen, sampled)
    }

    func test_aSample_recordsWhatItHeld_beforeTheMappings() async throws {
        try prepare()
        state.runOptions = .make(sample: Sample(size: 3, seed: 7, seedIsChosen: false))

        let changes = try await DiscoverMutationPoints().run(with: state)

        guard case let .sampleSelected(selection)? = changes.first else {
            return XCTFail("Expected the sample first, got \(changes)")
        }
        XCTAssertEqual(selection, SampleSelection(size: 3, seed: 7, mutantsSampledFrom: 5, mutantsSampled: 3))
        state.apply(changes)
        XCTAssertEqual(state.sampleSelection, selection)
    }

    // The sample first: every shard of a sampled split holds part of the same sample.
    func test_theShardsOfASampledSplit_testTheSampleOnceBetweenThem() async throws {
        try prepare()
        let sample = Sample(size: 3, seed: 7, seedIsChosen: false)
        let sampled = try await keys(discovering: sample)

        var tested: [MutantKey] = []
        for index in 1...2 {
            let shard = Shard(index: index, count: 2)
            tested += (try? await keys(discovering: sample, shard: shard)) ?? []
        }
        XCTAssertEqual(Set(tested), Set(sampled))
        XCTAssertEqual(tested.count, sampled.count)
    }

    func test_theConsole_saysWhatTheSampleHolds() throws {
        let mapping = try SchemataMutationMapping.make(
            filePath: "/project_mutated/Sources/Sum.swift",
            (source: "let value = a == b", schemata: [.make(filePath: "/project_mutated/Sources/Sum.swift")])
        )
        let partial = SampleSelection(size: 1, seed: 7, mutantsSampledFrom: 9, mutantsSampled: 1)

        Logger().mutationsDiscoveryFinished(mutations: [mapping], sample: (partial, seedIsChosen: false))
        Logger().mutationsDiscoveryFinished(
            mutations: [mapping],
            sample: (SampleSelection(size: 50, seed: 7, mutantsSampledFrom: 1, mutantsSampled: 1), seedIsChosen: false)
        )
        Logger().mutationsDiscoveryFinished(
            mutations: [mapping],
            sample: (SampleSelection(size: 4, seed: 7, mutantsSampledFrom: 9, mutantsSampled: 4), seedIsChosen: true),
            shard: .make(index: 2, count: 3, mutantsInAllShards: 4)
        )
        // More than 3, but the last place taken had repeats enough to hold them all.
        Logger().mutationsDiscoveryFinished(
            mutations: [mapping],
            sample: (SampleSelection(size: 3, seed: 7, mutantsSampledFrom: 5, mutantsSampled: 5), seedIsChosen: false)
        )

        XCTAssertEqual(printer.linesPassed, [
            "✅ In total, SwiftMutator discovered 9 mutants, and the sample of 1 holds 1 of them, in 1 files",
            "✅ In total, SwiftMutator discovered 1 mutants in 1 files, no more than the sample of 50, which holds "
                + "them all",
            "✅ In total, SwiftMutator discovered 9 mutants, the sample of 4 holds 4 of them, and shard 2 of 3 holds 1 "
                + "of those, in 1 files",
            "🎲 SwiftMutator chose the sample's seed, 7: --seed 7 takes the same sample again.",
            "✅ In total, SwiftMutator discovered 1 mutants in 1 files, and the sample of 3 holds them all",
        ])
    }

    // A small sample split many ways leaves some shards empty, which say how many the sample held, of how many.
    func test_anEmptyShardOfASample_saysTheSampleHeldTheMutants() async throws {
        try prepare()
        let sample = Sample(size: 1, seed: 7, seedIsChosen: false)
        let sampled = try await keys(discovering: sample)
        let only = try XCTUnwrap(sampled.first)
        let empty = Shard(index: Shard.index(ofPlace: only, among: 2) == 1 ? 2 : 1, count: 2)
        state.runOptions = .make(shard: empty, sample: sample)

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertEqual(
                "\(error)",
                "ℹ️ Shard \(empty.index) of 2 doesn't hold the only mutant in the sample, of the 5 discovered, so there "
                    + "is nothing to mutate."
            )
        }
        let selection = SampleSelection(size: 2, seed: 7, mutantsSampledFrom: 9, mutantsSampled: 2)
        XCTAssertEqual(
            "\(EmptyShard(shard: Shard(index: 3, count: 4), mutantsInAllShards: 2, sample: selection))",
            "ℹ️ Shard 3 of 4 holds none of the 2 mutants in the sample, of the 9 discovered, so there is nothing to "
                + "mutate."
        )
    }

    // A shard's hash doesn't depend on the seed, so its results are a random part of the sample: its own report gives
    // a margin from them, for the mutants sampled from.
    func test_aSampledShardsReport_countsTheSample_andGivesAMarginFromItsResults() throws {
        let outcome = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .failed)],
            shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2)),
            sample: SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2)
        )
        let margin = SampleScope.marginOfError(killed: 1, scored: 1, sampled: 1, from: 40)

        let plain = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(
            plain.contains("Only the mutants in shard 1 of 2 were tested, of 2 in every shard of the sample.")
        )
        XCTAssertTrue(
            plain.contains(
                "Only a sample of 2 of the 40 mutants discovered was tested (seed 9), and the margin is from the 1 of "
                    + "them here: a whole run's score is within " + String(format: "%.1f", margin) + " points"
            ),
            plain
        )
        let html = HTMLReporter().report(from: outcome)
        XCTAssertTrue(html.contains("Shard tested, of 2 mutants in the sample"))
        XCTAssertTrue(html.contains("1 of 2, score ± " + String(format: "%.1f", margin)), html)
    }

    // A stopped run's results are its first files', so a shard's, or a whole sample's, that stopped gives none.
    func test_aSampleCutShort_givesNoMargin_andSaysWhy() {
        let outcome = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .failed)],
            shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2)),
            sample: SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2),
            sampleIsCutShort: true
        )

        let plain = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(
            plain.contains(
                "and 1 of them have a result, so no margin is given: the others have none yet, so these are the first "
                    + "ones tested, not a random part of the sample."
            ),
            plain
        )
        XCTAssertTrue(HTMLReporter().report(from: outcome).contains("2, 1 with a result"))
    }

    func test_theReports_sayWhatTheSampleTested_andTheMargin() throws {
        let outcome = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .failed), .make(testSuiteOutcome: .passed)],
            sample: SampleSelection(size: 2, seed: 1234, mutantsSampledFrom: 40, mutantsSampled: 2)
        )
        let margin = SampleScope.marginOfError(killed: 1, scored: 2, sampled: 2, from: 40)

        XCTAssertTrue(
            PlainTextReporter().report(from: outcome).contains(
                "Only a sample of 2 of the 40 mutants discovered was tested (seed 1234): a whole run's score is within "
                    + String(format: "%.1f", margin) + " points of this one, at 95% confidence."
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        let sample = try XCTUnwrap(json["sample"] as? [String: Any])
        XCTAssertEqual(sample["mutantsSampled"] as? Int, 2)
        XCTAssertEqual(sample["mutantsSampledFrom"] as? Int, 40)
        XCTAssertEqual(sample["seed"] as? Int, 1234)
        XCTAssertEqual(try XCTUnwrap(sample["marginOfError"] as? Double), margin, accuracy: 1e-9)
        XCTAssertTrue(HTMLReporter().report(from: outcome).contains("Sample tested, of 40 mutants (seed 1234)"))
    }

    // A sample that held every mutant is the whole run, which the reports say nothing of.
    func test_aReportOfAWholeSample_orNoSample_saysNothingOfIt() throws {
        for sample in [nil, SampleSelection(size: 50, seed: 1, mutantsSampledFrom: 2, mutantsSampled: 2)] {
            let outcome = MutationTestOutcome(mutations: [.make(testSuiteOutcome: .failed)], sample: sample)

            XCTAssertFalse(PlainTextReporter().report(from: outcome).contains("sample"))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
            )
            XCTAssertNil(json["sample"])
            XCTAssertFalse(HTMLReporter().report(from: outcome).contains("Sample tested"))
        }
    }

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
        let sample = Sample(size: 2, seed: 1234, seedIsChosen: false)
        let sampled = try await keys(discovering: sample)
        state.runOptions = .make(sample: sample)

        state.apply(try await DiscoverMutationPoints().run(with: state))

        XCTAssertEqual(state.keysLeftOutOfTheSample, Set(wholeRun).subtracting(sampled))
        XCTAssertFalse(state.keysLeftOutOfTheSample.isEmpty)
    }

    // A whole run's results reused by a sample: most of them aren't of its mutants, which is no loss.
    func test_aReuseOfAnotherSample_saysWhy_ratherThanWarning() {
        let sample = Sample(size: 500, seed: 1234, seedIsChosen: false)

        XCTAssertNil(ResumeSummary.sampleChange(from: nil, to: nil))
        XCTAssertNil(ResumeSummary.sampleChange(from: sample, to: Sample(size: 500, seed: 1234, seedIsChosen: true)))
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

private extension SampleRunTests {
    func summary(
        outsideTheSample: Int,
        toTest: Int = 1,
        sampleIsPartial: Bool = false,
        selectionChange: String? = nil
    ) -> ResumeSummary {
        ResumeSummary(
            path: "/logs/results.jsonl",
            reused: 4,
            toTest: toTest,
            retestedBecause: toTest == 0 ? [:] : [.notRecorded: toTest],
            noLongerDiscovered: 0,
            outsideTheSample: outsideTheSample,
            sampleIsPartial: sampleIsPartial,
            discoveredBefore: 5,
            coverageChange: nil,
            forced: [],
            waived: [],
            notices: [],
            selectionChange: selectionChange
        )
    }

    /// The keys of the mutants discovery keeps with `sample` and `shard`, in job order; nil discovers every one.
    func keys(discovering sample: Sample?, shard: Shard? = nil) async throws -> [MutantKey] {
        state.runOptions = .make(shard: shard, sample: sample)
        let changes = try await DiscoverMutationPoints().run(with: state)
        let mappings = changes.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first ?? []
        return MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: state.mutatedProjectDirectoryURL)
    }

    func prepare() throws {
        let project = try makeTemporaryDirectory()
        let path = "\(project)/Check.swift"
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.sourceFileCandidates = [path]
    }
}
