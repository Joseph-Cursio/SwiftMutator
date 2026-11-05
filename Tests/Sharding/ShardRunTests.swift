@testable import muterCore
import Rainbow
import TestingExtensions
import XCTest

/// What a `--shard` run discovers, and what it says: on the console, in its reports, and when it reuses an earlier
/// run's results.
final class ShardRunTests: MuterTestCase {
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

    func test_theShards_testEveryMutantOnce_eachWithItsKeyInTheWholeRun() async throws {
        try prepare()
        let wholeRun = try await keys(discovering: nil)

        var tested: [MutantKey] = []
        for index in 1...3 {
            let shard = Shard(index: index, count: 3)
            let kept = (try? await keys(discovering: shard)) ?? []
            XCTAssertEqual(kept, wholeRun.filter(shard.holds), "shard \(shard)")
            tested += kept
        }
        XCTAssertEqual(
            tested.sorted { $0.description < $1.description },
            wholeRun.sorted { $0.description < $1.description }
        )
    }

    func test_aShard_recordsWhatEveryShardHolds() async throws {
        try prepare()
        let found = try await nonEmptyShard(of: 2)
        let shard = try XCTUnwrap(found)
        state.runOptions = .make(shard: shard)

        let changes = try await DiscoverMutationPoints().run(with: state)

        guard case let .shardSelected(selection)? = changes.first else {
            return XCTFail("Expected the shard first, got \(changes)")
        }
        XCTAssertEqual(selection.shard, shard)
        XCTAssertEqual(selection.mutantsInAllShards, 5)
        state.apply(changes)
        XCTAssertEqual(state.shardSelection, selection)
    }

    func test_aShardWithNoMutant_stillSaysWhatWasDropped() async throws {
        try prepare(source: """
        import Foundation
        func other(a: Int) -> Bool {
            return a == 3
        }
        guard let name = Int.max > 1 ? "name" : nil else { exit(1) }
        """)
        let discovered = try await keys(discovering: nil)
        let only = try XCTUnwrap(discovered.first)
        state.runOptions = .make(shard: Shard(index: Shard.index(ofPlace: only, among: 2) == 1 ? 2 : 1, count: 2))
        var dropped: [DroppedMutant] = []
        let subscription = current.events.observe { event in
            if case let .mutantsDropped(mutants) = event {
                dropped += mutants
            }
        }
        defer { subscription.cancel() }

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertTrue(error is EmptyShard, "\(error)")
        }

        XCTAssertEqual(dropped.map(\.position.line), [5, 5, 5])
    }

    func test_aShardWithNoMutant_leavesNothingToMutate() async throws {
        try prepare(source: "func other(a: Int) -> Bool {\n    return a == 3\n}\n")
        let discovered = try await keys(discovering: nil)
        let only = try XCTUnwrap(discovered.first)
        let empty = Shard(index: Shard.index(ofPlace: only, among: 2) == 1 ? 2 : 1, count: 2)
        state.runOptions = .make(shard: empty)

        await AssertThrowsError(try await DiscoverMutationPoints().run(with: state)) { error in
            XCTAssertEqual(error as? EmptyShard, EmptyShard(shard: empty, mutantsInAllShards: 1))
        }
        XCTAssertEqual(
            "\(EmptyShard(shard: empty, mutantsInAllShards: 1))",
            "ℹ️ Shard \(empty.index) of 2 doesn't hold the only mutant discovered, so there is nothing to mutate."
        )
        XCTAssertEqual(
            "\(EmptyShard(shard: Shard(index: 3, count: 4), mutantsInAllShards: 2))",
            "ℹ️ Shard 3 of 4 holds none of the 2 mutants discovered, so there is nothing to mutate."
        )
        // Not a failure, so no banner asking for a bug report.
        XCTAssertEqual(
            Run.message(showing: EmptyShard(shard: Shard(index: 3, count: 4), mutantsInAllShards: 2)),
            "ℹ️ Shard 3 of 4 holds none of the 2 mutants discovered, so there is nothing to mutate."
        )
    }

    func test_theConsole_saysHowManyEveryShardHolds_andThisOne() throws {
        let mapping = try SchemataMutationMapping.make(
            filePath: "/project_mutated/Sources/Sum.swift",
            (source: "let value = a == b", schemata: [.make(filePath: "/project_mutated/Sources/Sum.swift")])
        )
        let logger = Logger()

        logger.mutationsDiscoveryFinished(mutations: [mapping], shard: .make(index: 2, count: 3, mutantsInAllShards: 7))

        XCTAssertEqual(
            printer.linesPassed,
            ["✅ In total, SwiftMutator discovered 7 mutants, and shard 2 of 3 holds 1 of them, in 1 files"]
        )
        XCTAssertEqual(logger.numberOfMutationPoints, 1)
    }

    func test_theReports_sayWhichShardWasTested() throws {
        let outcome = MutationTestOutcome(shards: ShardScope(.make(index: 1, count: 2, mutantsInAllShards: 2463)))

        XCTAssertTrue(
            PlainTextReporter().report(from: outcome).contains(
                "Only the mutants in shard 1 of 2 were tested, of 2463 discovered in every shard."
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        let shards = try XCTUnwrap(json["shards"] as? [String: Any])
        XCTAssertEqual(shards["indices"] as? [Int], [1])
        XCTAssertEqual(shards["count"] as? Int, 2)
        XCTAssertEqual(shards["mutantsInAllShards"] as? Int, 2463)
        XCTAssertTrue(HTMLReporter().report(from: outcome).contains("Shard tested, of 2463 mutants"))
    }

    // As a report of merged shards says, when some are missing.
    func test_aScopeOfSeveralShards_namesThemAll() {
        let scope = ShardScope(indices: [3, 1], count: 4, mutantsInAllShards: 2463)

        XCTAssertEqual(scope.indices, [1, 3])
        XCTAssertEqual(
            scope.sentence(),
            "Only the mutants in shards 1 and 3 of 4 were tested, of 2463 discovered in every shard."
        )
        // A sampled split's shards count the sample's mutants.
        XCTAssertEqual(
            scope.sentence(sampled: true),
            "Only the mutants in shards 1 and 3 of 4 were tested, of 2463 in every shard of the sample."
        )
        XCTAssertTrue(
            HTMLReporter().report(from: MutationTestOutcome(shards: scope)).contains("Shards tested, of 2463")
        )
    }

    func test_aReportWithoutAShard_saysNothingOfIt() throws {
        let outcome = MutationTestOutcome()

        XCTAssertFalse(PlainTextReporter().report(from: outcome).contains("shard"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(JsonReporter().report(from: outcome).utf8)) as? [String: Any]
        )
        XCTAssertNil(json["shards"])
        XCTAssertFalse(HTMLReporter().report(from: outcome).contains("Shard tested"))
    }

    // A whole run's results reused by a shard: most of them aren't of its mutants, which is no loss.
    func test_aReuseOfAnotherShard_saysWhy_ratherThanWarning() {
        let first = Shard(index: 1, count: 2)

        XCTAssertNil(ResumeSummary.shardChange(from: nil, to: nil))
        XCTAssertNil(ResumeSummary.shardChange(from: first, to: first))
        XCTAssertEqual(
            ResumeSummary.shardChange(from: nil, to: first),
            "This run tests only shard 1 of 2, so no earlier result of another shard's mutant is reused."
        )
        XCTAssertEqual(
            ResumeSummary.shardChange(from: first, to: nil),
            "That run tested only shard 1 of 2, so this run's other mutants have no earlier result."
        )
        XCTAssertEqual(
            ResumeSummary.shardChange(from: first, to: Shard(index: 2, count: 3)),
            "That run tested shard 1 of 2, and this one tests shard 2 of 3, so only the mutants in both have an "
                + "earlier result."
        )
        XCTAssertEqual(
            ResumeSummary.shardChange(from: first, to: Shard(index: 2, count: 2)),
            "That run tested shard 1 of 2, and this one tests shard 2 of 2, which share no mutant, so no earlier "
                + "result is reused."
        )
    }

    func test_aReuseWithAnotherChoiceAndShard_saysBoth() {
        let selection = ChangeSelection.make(ref: "origin/main")

        XCTAssertEqual(
            ResumeSummary.selectionChange(from: (nil, nil, nil), to: (selection, Shard(index: 1, count: 2), nil)),
            "This run mutates only what changed since the merge base of origin/main and HEAD (ba5e000), so no earlier "
                + "result of another mutant is reused. This run tests only shard 1 of 2, so no earlier result of "
                + "another shard's mutant is reused."
        )
        XCTAssertNil(ResumeSummary.selectionChange(from: (selection, nil, nil), to: (selection, nil, nil)))
    }
}

private extension ShardRunTests {
    /// The keys of the mutants discovery keeps with `shard`, in job order; nil discovers every one.
    func keys(discovering shard: Shard?) async throws -> [MutantKey] {
        state.runOptions = .make(shard: shard)
        let changes = try await DiscoverMutationPoints().run(with: state)
        let mappings = changes.compactMap { change -> [SchemataMutationMapping]? in
            guard case let .mutationMappingsDiscovered(mappings) = change else { return nil }
            return mappings
        }.first ?? []
        return MutantKey.keys(for: mappings.flatMap(\.mutationSchemata), under: state.mutatedProjectDirectoryURL)
    }

    /// A shard of `count` that holds some of the mutants.
    func nonEmptyShard(of count: Int) async throws -> Shard? {
        let first = try await keys(discovering: nil).first
        return first.map { Shard(index: Shard.index(ofPlace: $0, among: count), count: count) }
    }

    func prepare(source: String? = nil) throws {
        let project = try makeTemporaryDirectory()
        let path = "\(project)/Check.swift"
        try (source ?? self.source).write(toFile: path, atomically: true, encoding: .utf8)
        state.mutatedProjectDirectoryURL = URL(fileURLWithPath: project, isDirectory: true)
        state.sourceFileCandidates = [path]
    }
}
