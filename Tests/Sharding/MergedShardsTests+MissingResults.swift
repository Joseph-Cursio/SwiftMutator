@testable import muterCore
import XCTest

extension MergedShardsTests {
    // A shard with no mutant writes no results file; one whose file is missing leaves its mutants without results.
    func test_aShardWhoseFileIsntGiven_isSaid_andFailsTheReportOnlyIfItHoldsMutants() throws {
        let complete = try merge(
            file("/a/results.jsonl", header(1, count: 3, mutantsPerShard: [2, 1, 0]), sum3, sum9, end()),
            file("/b/results.jsonl", header(2, count: 3, mutantsPerShard: [2, 1, 0]), alpha5, end())
        )
        XCTAssertFalse(complete.lacksResults)
        XCTAssertNil(complete.mutationTestOutcome().shards)
        XCTAssertEqual(complete.statusLines().last, "Shard 3 of 3 holds no mutant, so it has no results file.")

        let missing = try merge(
            file("/a/results.jsonl", header(1, count: 3, mutantsDiscovered: 1, mutantsPerShard: [1, 1, 1]), sum3),
            file("/c/results.jsonl", header(3, count: 3, mutantsDiscovered: 1, mutantsPerShard: [1, 1, 1]))
        )
        XCTAssertTrue(missing.lacksResults)
        XCTAssertEqual(
            missing.mutationTestOutcome().shards,
            ShardScope(indices: [1, 3], count: 3, mutantsInAllShards: 3)
        )
        XCTAssertEqual(missing.statusLines(), [
            "Report of 1 of 3 mutants, merged from the results files of 2 of 3 shards.",
            "Shard 1 of 3, 1 of its 1 mutant, from /a/results.jsonl: "
                + "the run has no end line, so it is still running, or it was killed or crashed.",
            "Shard 3 of 3, 0 of its 1 mutant, from /c/results.jsonl: "
                + "the run has no end line, so it is still running, or it was killed or crashed.",
            "No results were given for shard 2 of 3, which holds 1 mutant.",
        ])
    }

    // A merge of one, so that a glob that finds one file is judged as one that finds two.
    func test_oneShardsFileAlone_isSaidAsAnyFile_andLacksTheShardsNotGiven() throws {
        let alone = try merge(file("/a/results.jsonl", header(1), sum3, sum9, end()))

        XCTAssertTrue(alone.lacksResults)
        XCTAssertEqual(
            alone.mutationTestOutcome().shards,
            ShardScope(indices: [1], count: 2, mutantsInAllShards: 3)
        )
        XCTAssertEqual(alone.statusLines(), [
            "Report of 2 of 2 mutants in shard 1 of 2, from /a/results.jsonl: the run finished.",
            "No results were given for shard 2 of 2, which holds 1 mutant.",
        ])

        let others = try merge(file("/a/results.jsonl", header(1, mutantsPerShard: [3, 0]), sum3, sum9, alpha5, end()))
        XCTAssertFalse(others.lacksResults)
        XCTAssertNil(others.mutationTestOutcome().shards)
    }

    // Its own job failed, as killed by a CI timeout or cancelled: the report would score fewer mutants.
    func test_aShardWithFewerResultsThanMutants_failsTheReport() throws {
        let interrupted = try merge(
            file("/a/results.jsonl", header(1), sum3, end(.interrupted, detail: "SIGTERM")),
            file("/b/results.jsonl", header(2), alpha5, end())
        )
        XCTAssertTrue(interrupted.lacksResults)
        XCTAssertEqual(
            interrupted.statusLines()[1],
            "Shard 1 of 2, 1 of its 2 mutants, from /a/results.jsonl: the run was interrupted by SIGTERM."
        )

        // Every mutant has its result, so how the run ended doesn't matter.
        let tested = try merge(
            file("/a/results.jsonl", header(1), sum3, sum9, end(.interrupted, detail: "SIGTERM")),
            file("/b/results.jsonl", header(2), alpha5)
        )
        XCTAssertFalse(tested.lacksResults)
    }

    // Each file's last record of a key, as a single file's report takes it, and none of a key a later line retired.
    func test_aResumedShard_givesItsLatestResults() throws {
        let retested = MutantResult.make(session: 2, path: "Sources/Sum.swift", line: 9, outcome: .failed)
        let merged = try merge(
            file(
                "/a/results.jsonl",
                header(1),
                sum3,
                sum9,
                end(.interrupted),
                header(1, session: 2),
                ResultsRetired(session: 2, keys: [sum9.key]),
                retested,
                end()
            ),
            file("/b/results.jsonl", header(2), alpha5, end())
        )

        XCTAssertFalse(merged.lacksResults)
        XCTAssertEqual(merged.latest[sum9.key]?.outcome, .failed)
        XCTAssertEqual(merged.mutationTestOutcome().mutations.map(\.testSuiteOutcome), [.failed, .failed, .failed])
        XCTAssertTrue(
            merged.statusLines().contains(
                "In shard 1 of 2's file: of these, 1 was tested in the last session, session 2, and 1 in session 1."
            )
        )
    }

    // Where a shard's kept results were tested, so the merged report marks them as a whole run's would.
    func test_aReusingShard_keepsWhereItsResultsWereTested() throws {
        let kept = MutantResult.make(
            path: "Sources/Sum.swift",
            line: 3,
            outcome: .failed,
            reusedFrom: ReusedFrom(resultsFile: "/old/results.jsonl", session: 1, despiteChanges: false)
        )
        let merged = try merge(
            file("/a/results.jsonl", header(1), kept, sum9, end()),
            file("/b/results.jsonl", header(2), alpha5, end())
        )

        XCTAssertEqual(
            merged.mutationTestOutcome().mutations.compactMap(\.reusedFrom),
            [ReusedFrom(resultsFile: "/old/results.jsonl", session: 1, despiteChanges: false)]
        )
        XCTAssertTrue(
            merged.statusLines().contains(
                "In shard 1 of 2's file: of these, 1 was tested and 1 kept by --reuse, tested in /old/results.jsonl."
            )
        )
    }

    func test_aShardThatStoppedOnAnError_failsTheReport() throws {
        let merged = try merge(
            file("/a/results.jsonl", header(1), end(.aborted, detail: "tooManyBuildErrors")),
            file("/b/results.jsonl", header(2), alpha5, end())
        )

        XCTAssertTrue(merged.lacksResults)
        XCTAssertEqual(
            merged.statusLines()[1],
            "Shard 1 of 2, 0 of its 2 mutants, from /a/results.jsonl: the run stopped on an error (tooManyBuildErrors)."
        )
    }

    // A shard's run that stopped on an error gives `report` the status it exited with, the first such shard's by its
    // index; one that lacks results otherwise, interrupted or missing, gives 4, as the whole run didn't test every
    // mutant. A shard whose baseline failed has no file, so it is missing.
    func test_exitStatus_ofAMergeThatLacksResults() throws {
        let complete = try merge(
            file("/a/results.jsonl", header(1), sum3, sum9, end()),
            file("/b/results.jsonl", header(2), alpha5, end())
        )
        XCTAssertNil(complete.exitStatus)
        let interrupted = try merge(
            file("/a/results.jsonl", header(1), sum3, end(.interrupted, detail: "SIGTERM")),
            file("/b/results.jsonl", header(2), alpha5, end())
        )
        XCTAssertEqual(interrupted.exitStatus, .abortedMidRun)
        let missing = try merge(file("/a/results.jsonl", header(1), sum3, sum9, end()))
        XCTAssertEqual(missing.exitStatus, .abortedMidRun)
        let stopped = try merge(
            file("/b/results.jsonl", header(2), end(.aborted, detail: "MuterError")),
            file("/a/results.jsonl", header(1), sum3, end(.aborted, detail: "tooManyBuildErrors"))
        )
        XCTAssertEqual(stopped.exitStatus, .abortedMidRun)
        let unexpected = try merge(
            file("/b/results.jsonl", header(2), end(.aborted, detail: "tooManyBuildErrors")),
            file("/a/results.jsonl", header(1), sum3, end(.aborted, detail: "MuterError"))
        )
        XCTAssertEqual(unexpected.exitStatus, .stoppedOnAnError)
    }
}
