@testable import muterCore
import XCTest

/// `report` of several shards' results files: what it refuses to merge, and what it makes of the rest.
final class MergedShardsTests: XCTestCase {
    func test_twoShards_mergeIntoTheWholeRunsOutcome_inJobOrder() throws {
        let merged = try merge(
            file("/a/results.jsonl", header(1), sum9, sum3, end(testDuration: 40)),
            file("/b/results.jsonl", header(2, mutantsDiscovered: 1), alpha5, end(testDuration: 55.5))
        )

        let outcome = merged.mutationTestOutcome()
        XCTAssertEqual(outcome.mutations.map(\.point.filePath), [
            "/project_mutated/Sources/Alpha.swift",
            "/project_mutated/Sources/Sum.swift",
            "/project_mutated/Sources/Sum.swift",
        ])
        XCTAssertEqual(outcome.mutations.map(\.point.position.line), [5, 3, 9])
        XCTAssertEqual(outcome.testDuration, 55.5)
        XCTAssertNil(outcome.shards)
        XCTAssertFalse(merged.lacksResults)
        XCTAssertEqual(merged.statusLines(), [
            "Report of 3 of 3 mutants, merged from the results files of 2 of 2 shards.",
            "Shard 1 of 2, 2 of its 2 mutants, from /a/results.jsonl: the run finished.",
            "Shard 2 of 2, 1 of its 1 mutant, from /b/results.jsonl: the run finished.",
        ])
    }

    // Each machine's copy is somewhere of its own; the report names every file as the reference shard's copy does.
    func test_everyResult_isUnderTheReferenceShardsPaths() throws {
        let merged = try merge(
            file("/b/results.jsonl", header(2, mutantsDiscovered: 1, mutatedProjectPath: "/ci/p_mutated"), alpha5),
            file("/a/results.jsonl", header(1), sum3, sum9)
        )

        XCTAssertEqual(
            Set(merged.mutationTestOutcome().mutations.map(\.point.filePath)),
            ["/project_mutated/Sources/Alpha.swift", "/project_mutated/Sources/Sum.swift"]
        )
        XCTAssertEqual(merged.reference.path, "/a/results.jsonl")
    }

    func test_everyReasonAboutTheFiles_isGivenAtOnce() {
        assertRefused(
            [
                file("/a/results.jsonl", header(1)),
                file("/whole/results.jsonl", ResultsHeader.make(project: Self.tree)),
                file("/a/results.jsonl", header(1)),
            ],
            [
                .notAShard(path: "/whole/results.jsonl"),
                .givenTwice(Shard(index: 1, count: 2), paths: ["/a/results.jsonl", "/a/results.jsonl"]),
            ]
        )
    }

    func test_aFileThatIsntAShards_isRefused() {
        assertRefused(
            [
                file("/a/results.jsonl", header(1), sum3),
                file("/whole/results.jsonl", ResultsHeader.make(project: Self.tree), sum3),
            ],
            [.notAShard(path: "/whole/results.jsonl")],
            saying: "'/whole/results.jsonl' isn't the results file of a shard (run --shard), so it can't be merged "
                + "with others."
        )
    }

    // As a header edited by hand might be: nothing then shows what the shard holds, or which shards are missing.
    func test_aShardWhoseCountsDontHoldTogether_isRefused() {
        let reference = file("/a/results.jsonl", header(1))
        let inconsistent = [
            header(3),
            header(1, count: 0, mutantsPerShard: []),
            header(2, mutantsPerShard: [2]),
            header(2, mutantsPerShard: [2, 2]),
            header(2, mutantsDiscovered: 2),
            header(2, mutantsInAllShards: -1, mutantsPerShard: [2, -3]),
            // Holds together but for the cap.
            header(2, count: 1_001, mutantsInAllShards: 1, mutantsPerShard: [0, 1] + Array(repeating: 0, count: 999)),
            header(2, mutantsInAllShards: 0, mutantsPerShard: [Int.max, 1]),
            header(2, mutantsInAllShards: Int.max, mutantsPerShard: [Int.max, Int.max]),
        ]
        for header in inconsistent {
            assertRefused(
                [reference, file("/b/results.jsonl", header)],
                [.inconsistentShard(path: "/b/results.jsonl")]
            )
        }
        XCTAssertEqual(
            MergeRefusal.inconsistentShard(path: "/b/results.jsonl").description,
            "'/b/results.jsonl' records a shard whose counts don't hold together, as a header edited by hand might, so "
                + "nothing shows what the shard holds."
        )
    }

    func test_shardsOfDifferentSplits_areRefused() {
        assertRefused(
            [
                file("/a/results.jsonl", header(1)),
                file("/b/results.jsonl", header(2, count: 3, mutantsPerShard: [1, 1, 1])),
            ],
            [
                .otherSplits([
                    MergeRefusal.ShardFile(path: "/a/results.jsonl", shard: Shard(index: 1, count: 2)),
                    MergeRefusal.ShardFile(path: "/b/results.jsonl", shard: Shard(index: 2, count: 3)),
                ]),
            ],
            saying: "The files are shards of different splits: '/a/results.jsonl' is shard 1 of 2 and "
                + "'/b/results.jsonl' is shard 2 of 3."
        )
    }

    func test_aShardGivenTwice_isRefused() {
        assertRefused(
            [file("/a/results.jsonl", header(1)), file("/c/results.jsonl", header(1)), file("/b/r.jsonl", header(2))],
            [.givenTwice(Shard(index: 1, count: 2), paths: ["/a/results.jsonl", "/c/results.jsonl"])],
            saying: "The results file of shard 1 of 2 is given more than once: '/a/results.jsonl' and "
                + "'/c/results.jsonl'."
        )
        assertRefused(
            [file("/a/results.jsonl", header(1)), file("/a/results.jsonl", header(1))],
            [.givenTwice(Shard(index: 1, count: 2), paths: ["/a/results.jsonl", "/a/results.jsonl"])],
            saying: "The results file of shard 1 of 2 is given 2 times: '/a/results.jsonl'."
        )
    }
}
