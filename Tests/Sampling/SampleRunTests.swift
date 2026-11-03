@testable import muterCore
import Rainbow
import TestingExtensions
import XCTest

/// What a `--sample` run discovers, and what it says: on the console, in its reports, and when it reuses an earlier
/// run's results.
final class SampleRunTests: MuterTestCase {
    private let state = MutationTestState()

    // Line 2 `<`, lines 8 and 9 statements RemoveSideEffects removes, line 13 `==`.
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
        XCTAssertEqual(selection, SampleSelection(size: 3, seed: 7, mutantsSampledFrom: 4, mutantsSampled: 3))
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
                "ℹ️ Shard \(empty.index) of 2 doesn't hold the only mutant in the sample, of the 4 discovered, so there "
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

    func test_aSampledShardsReport_countsTheSample_andGivesNoMarginUntilMerged() throws {
        let outcome = MutationTestOutcome(
            mutations: [.make(testSuiteOutcome: .failed)],
            shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2)),
            sample: SampleSelection(size: 2, seed: 9, mutantsSampledFrom: 40, mutantsSampled: 2)
        )

        let plain = PlainTextReporter().report(from: outcome)
        XCTAssertTrue(
            plain.contains("Only the mutants in shard 1 of 2 were tested, of 2 in every shard of the sample.")
        )
        XCTAssertTrue(plain.contains("and 1 of them have a result, so no margin is given"))
        let html = HTMLReporter().report(from: outcome)
        XCTAssertTrue(html.contains("Shard tested, of 2 mutants in the sample"))
        XCTAssertTrue(html.contains("2, 1 with a result"))
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

        let outcome = MutationTestOutcome(records: [MutantResult](), under: header, testDuration: 0, shards: nil)

        XCTAssertEqual(outcome.sample, header.sample)
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
