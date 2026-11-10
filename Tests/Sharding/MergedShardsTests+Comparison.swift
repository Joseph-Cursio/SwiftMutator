@testable import muterCore
import XCTest

extension MergedShardsTests {
    // What a resume compares, but for the shard, which differs between shards by definition.
    func test_whatAResumeCompares_refuses_andOnlyTheBuildCanBeForced() throws {
        let files = [
            file("/a/results.jsonl", header(1)),
            file("/b/results.jsonl", header(2, operators: ["SwapTernary"], provenance: otherBuild)),
        ]

        assertRefused(files, [
            .differs(
                Shard(index: 2, count: 2),
                from: Shard(index: 1, count: 2),
                .selectionChanged(.init(
                    name: "operators",
                    was: #"["SwapTernary"]"#,
                    isNow: #"["RelationalOperatorReplacement"]"#
                ))
            ),
            .differs(
                Shard(index: 2, count: 2),
                from: Shard(index: 1, count: 2),
                .needsForce(.init(
                    name: "swiftMutator.executableSHA256",
                    was: #""ffff""#,
                    isNow: "\"\(Provenance.fixture.swiftMutator.executableSHA256 ?? "")\""
                ))
            ),
        ])
        XCTAssertEqual(
            MergeRefusal.differs(
                Shard(index: 2, count: 2),
                from: Shard(index: 1, count: 2),
                .selectionChanged(.init(name: "operators", was: #"["SwapTernary"]"#, isNow: #"["Other"]"#))
            ).description,
            #"operators is ["SwapTernary"] in shard 2 of 2, and ["Other"] in shard 1 of 2, so the shards chose "#
                + "their mutants differently."
        )

        let forced = try MergedShards.merge(
            [file("/a/results.jsonl", header(1)), file("/b/results.jsonl", header(2, provenance: otherBuild))]
                .map(read),
            forcing: true,
            ignoring: []
        )
        XCTAssertEqual(forced.forced, ["swiftMutator.executableSHA256"])
        XCTAssertEqual(
            forced.statusLines().last,
            "Merged although SwiftMutator differs between the shards (--force-merge)."
        )
    }

    // The merged run's details name every shard's file, in shard order, count every shard's sessions, and are
    // otherwise the first shard's.
    func test_theMergedRunsDetails_nameEveryShardsFile_andCountEveryShardsSessions() throws {
        let merged = try MergedShards.merge(
            [
                file("/b/results.jsonl", header(2), end(.interrupted), header(2, session: 2), end()),
                file("/a/results.jsonl", header(1)),
            ].map(read),
            forcing: false,
            ignoring: []
        )

        let run = try XCTUnwrap(merged.mutationTestOutcome().run)
        XCTAssertEqual(run.resultsFiles, ["/a/results.jsonl", "/b/results.jsonl"])
        XCTAssertEqual(run.sessions, 3)
        let first = merged.parts[0].header
        XCTAssertEqual(run.workers, first.workers)
        XCTAssertEqual(run.configuration, first.configuration)
        XCTAssertEqual(run.lines.first, "Results files: /a/results.jsonl, /b/results.jsonl (3 sessions)")
    }

    // A merged summary says the merged run was aborted if a shard's was, else interrupted if one was, else finished.
    func test_theMergedEnding_isTheWorstOfTheShards() throws {
        func ending(_ first: ResultsEnd.Reason, _ second: ResultsEnd.Reason) throws -> ResultsEnd.Reason? {
            try merge(
                file("/a/results.jsonl", header(1), end(first)),
                file("/b/results.jsonl", header(2), end(second))
            ).ending?.reason
        }

        XCTAssertEqual(try ending(.finished, .finished), .finished)
        XCTAssertEqual(try ending(.finished, .interrupted), .interrupted)
        XCTAssertEqual(try ending(.interrupted, .finished), .interrupted)
        XCTAssertEqual(try ending(.interrupted, .aborted), .aborted)
        XCTAssertEqual(try ending(.aborted, .interrupted), .aborted)
    }

    // How a shard's run ended is unknown while it is still running, or when its file isn't given.
    func test_theMergedEnding_isUnknown_whileAShardHasNoEndLine_orIsAbsent() throws {
        XCTAssertNil(try merge(file("/a/results.jsonl", header(1), end()), file("/b/results.jsonl", header(2))).ending)
        XCTAssertNil(try merge(file("/a/results.jsonl", header(1), sum3, sum9, end())).ending)
        // A shard with no mutants has nothing to say.
        XCTAssertEqual(
            try merge(file("/a/results.jsonl", header(1, mutantsPerShard: [3, 0]), sum3, sum9, alpha5, end())).ending,
            end()
        )
    }

    func test_projectFilesThatDiffer_refuse_unlessIgnored() throws {
        let other = ProjectTree(
            listedBy: .git,
            files: ["Sources/Sum.swift": "ab12", "README.md": "0000", "notes.txt": "1111"],
            excluded: [],
            treeSHA256: "9999"
        )
        let files = [file("/a/results.jsonl", header(1)), file("/b/results.jsonl", header(2, project: other))]

        let refusal = MergeRefusal.filesDiffer(
            Shard(index: 2, count: 2),
            from: Shard(index: 1, count: 2),
            [.init(path: "README.md", kind: .changed), .init(path: "notes.txt", kind: .added)]
        )
        let message = """
        2 project files differ between shard 1 of 2 and shard 2 of 2: README.md (differs), notes.txt (only in shard \
        2 of 2).
        If they can't change any test's result: --merge-ignoring 'README.md' --merge-ignoring 'notes.txt'
        """
        assertRefused(files, [refusal], saying: message)

        let merged = try MergedShards.merge(files.map(read), forcing: false, ignoring: ["README.md", "*.txt"])
        XCTAssertEqual(merged.waived, ["README.md", "notes.txt"])
        XCTAssertEqual(
            merged.statusLines().last,
            "Merged although 2 project files differ between the shards (--merge-ignoring): README.md, notes.txt."
        )
        // Either version could be the one a mutant was tested in, so no report shows a line from either.
        let digests = try XCTUnwrap(merged.mutationTestOutcome().sourceDigests)
        XCTAssertEqual(digests["README.md"], MergedShards.differsBetweenShards)
        XCTAssertEqual(digests["notes.txt"], MergedShards.differsBetweenShards)
    }

    // Only the config file and the reports the runs write are left out, as each shard leaves out its own.
    func test_whatEachShardLeftOut_isntCompared() throws {
        let withReport = ProjectTree(
            listedBy: .git,
            files: Self.tree.files.merging(["shard1.txt": "aaaa"]) { $1 },
            excluded: ["shard2.txt"],
            treeSHA256: "1234"
        )
        let reference = ProjectTree(
            listedBy: .git,
            files: Self.tree.files,
            excluded: ["shard1.txt"],
            treeSHA256: "5678"
        )

        XCTAssertNoThrow(try merge(
            file("/a/results.jsonl", header(1, project: reference)),
            file("/b/results.jsonl", header(2, project: withReport))
        ))
    }

    func test_aMutantTestedInTwoFiles_isRefused() {
        assertRefused(
            [file("/a/results.jsonl", header(1), sum3), file("/b/results.jsonl", header(2), sum3, alpha5)],
            [.testedTwice([sum3.key])],
            saying: "1 mutant has a result in more than one file: Sources/Sum.swift:3:22 RelationalOperatorReplacement."
        )
    }

    func test_theSameMutantsSplitDifferently_isRefused() {
        assertRefused(
            [
                file("/a/results.jsonl", header(1, mutantsPerShard: [2, 1])),
                file("/b/results.jsonl", header(2, mutantsPerShard: [1, 2])),
            ],
            [.splitDifferently(Shard(index: 2, count: 2), from: Shard(index: 1, count: 2))]
        )
    }
}
