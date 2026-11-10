@testable import muterCore
import XCTest

extension MergedShardsTests {
    // Coverage that differed between the machines can leave out mutants that only some of them discovered.
    func test_discoveriesThatDiffer_areSaid() throws {
        let merged = try merge(
            file("/a/results.jsonl", header(1), sum3),
            file("/b/results.jsonl", header(2, mutantsInAllShards: 4, mutantsPerShard: [2, 2], allKeysSHA256: "b22"))
        )

        XCTAssertFalse(merged.discoveriesAgree)
        XCTAssertEqual(
            merged.statusLines().first,
            "Report of 1 mutant, merged from the results files of 2 of 2 shards."
        )
        XCTAssertEqual(
            merged.statusLines().last,
            "The shards' runs didn't discover the same mutants: shard 1 of 2's discovered 3 mutants in all and shard "
                + "2 of 2's 4, so a mutant that some of them didn't discover may have no result."
        )
    }

    // The last header is what's compared, so a shard resumed with --force-resume says so here too.
    func test_aShardThatLetChangesThroughWhenResumed_isSaid() throws {
        let merged = try merge(
            file("/a/results.jsonl", header(1), header(1, session: 2, forced: ["toolchain.testCommandVersion"])),
            file("/b/results.jsonl", header(2, mutantsDiscovered: 1))
        )

        XCTAssertEqual(
            merged.statusLines().last,
            "Shard 1 of 2 kept results although changes were let through when it was resumed or reused: its headers' "
                + "forced and waived say which."
        )
    }

    // A shard's hash doesn't depend on the seed, so the shards given are a random part of the sample, whichever are
    // missing; one given with fewer results than mutants tested its first files only.
    func test_theShardsOfASample_haveAMargin_unlessOneGivenIsCutShort() throws {
        let sample = SampleSelection(size: 3, seed: 7, mutantsSampledFrom: 20, mutantsSampled: 3)

        let missing = try merge(file("/a/results.jsonl", header(1, sample: sample), sum3, sum9, end()))
        let stopped = try merge(
            file("/a/results.jsonl", header(1, sample: sample), sum3, end(.interrupted)),
            file("/b/results.jsonl", header(2, sample: sample), alpha5, end())
        )

        XCTAssertFalse(missing.mutationTestOutcome().sampleIsCutShort)
        XCTAssertNotNil(MuterTestReport(from: missing.mutationTestOutcome()).sample?.marginOfError)
        XCTAssertTrue(stopped.mutationTestOutcome().sampleIsCutShort)
        XCTAssertNil(MuterTestReport(from: stopped.mutationTestOutcome()).sample?.marginOfError)
        // One whose job was cancelled before its first mutant adds nothing, as if its file weren't given.
        let empty = try merge(
            file("/a/results.jsonl", header(1, sample: sample), sum3, sum9, end()),
            file("/b/results.jsonl", header(2, sample: sample), end(.interrupted))
        )
        XCTAssertFalse(empty.mutationTestOutcome().sampleIsCutShort)
    }

    func test_skippedLines_areSaidForTheirShard() throws {
        var data = try encoded(header(1), sum3)
        data += Data("garbled\n".utf8)
        let merged = try MergedShards.merge(
            [
                (path: "/a/results.jsonl", recorded: try RecordedResults.read(data, path: "/a/results.jsonl")),
                read(file("/b/results.jsonl", header(2, mutantsDiscovered: 1))),
            ],
            forcing: false,
            ignoring: []
        )

        XCTAssertTrue(merged.statusLines().contains("In shard 1 of 2's file: skipped 1 line that didn't read: 3."))
    }

    // After the shard's own line and before its skipped lines, as for a file that isn't a shard's.
    func test_aShardsSessions_areSaidForItsShard() throws {
        let retested = MutantResult.make(session: 2, path: "Sources/Sum.swift", line: 9, outcome: .failed)
        var data = try encoded(header(1), sum3, sum9, end(.interrupted), header(1, session: 2))
        data += Data("garbled\n".utf8)
        data += try encoded(ResultsRetired(session: 2, keys: [sum9.key]), retested)
        let resumed = (path: "/a/results.jsonl", recorded: try RecordedResults.read(data, path: "/a/results.jsonl"))

        let merged = try MergedShards.merge(
            [resumed, read(file("/b/results.jsonl", header(2), alpha5, end()))],
            forcing: false,
            ignoring: []
        )
        let alone = try MergedShards.merge([resumed], forcing: false, ignoring: [])

        XCTAssertEqual(Array(merged.statusLines().prefix(4)), [
            "Report of 3 of 3 mutants, merged from the results files of 2 of 2 shards.",
            "Shard 1 of 2, 2 of its 2 mutants, from /a/results.jsonl: "
                + "the run has no end line, so it is still running, or it was killed or crashed.",
            "In shard 1 of 2's file: of these, 1 was tested in the last session, session 2, and 1 in session 1.",
            "In shard 1 of 2's file: skipped 1 line that didn't read: 6.",
        ])
        XCTAssertEqual(Array(alone.statusLines().prefix(3)), [
            "Report of 2 of 2 mutants in shard 1 of 2, from /a/results.jsonl: "
                + "the run has no end line, so it is still running, or it was killed or crashed.",
            "Of these, 1 was tested in the last session, session 2, and 1 in session 1.",
            "Skipped 1 line that didn't read: 6.",
        ])
    }
}
