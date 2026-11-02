@testable import muterCore
import XCTest

/// `report` of several shards' results files: what it refuses to merge, and what it makes of the rest.
final class MergedShardsTests: XCTestCase {
    private static let tree = ProjectTree(
        listedBy: .git,
        files: ["Sources/Sum.swift": "ab12", "README.md": "ef56"],
        excluded: [],
        treeSHA256: "cd34"
    )

    // Shard 1 of 2 holds Sum.swift:3 and :9, shard 2 Alpha.swift:5.
    private let sum3 = MutantResult.make(path: "Sources/Sum.swift", line: 3, outcome: .failed)
    private let sum9 = MutantResult.make(path: "Sources/Sum.swift", line: 9, outcome: .passed)
    private let alpha5 = MutantResult.make(path: "Sources/Alpha.swift", line: 5, outcome: .failed)

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
        XCTAssertFalse(merged.stoppedOnAnError)
        XCTAssertEqual(merged.statusLines(), [
            "Report of 3 of 3 mutants, merged from the results files of 2 of 2 shards.",
            "Shard 1 of 2, 2 of its 2 mutants, from /a/results.jsonl: the run finished.",
            "Shard 2 of 2, 1 of its 1 mutants, from /b/results.jsonl: the run finished.",
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

    func test_shardsOfDifferentSplits_areRefused() {
        assertRefused(
            [file("/a/results.jsonl", header(1)), file("/b/results.jsonl", header(2, count: 3))],
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

    // What a resume compares, but for the shard, which differs between shards by definition.
    func test_whatAResumeCompares_refuses_andOnlyTheBuildCanBeForced() throws {
        var otherBuild = Provenance.fixture
        otherBuild = Provenance(
            swiftMutator: .init(version: "0.2.0", executablePath: nil, executableSHA256: "ffff"),
            toolchain: otherBuild.toolchain,
            processIdentifier: 1,
            host: "ci.local",
            arguments: []
        )
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

    // A shard with no mutant writes no results file; one whose file is missing leaves its mutants without results.
    func test_aShardWhoseFileIsntGiven_isSaid_andFailsTheReportOnlyIfItHoldsMutants() throws {
        let complete = try merge(
            file("/a/results.jsonl", header(1, count: 3, mutantsPerShard: [2, 1, 0])),
            file("/b/results.jsonl", header(2, count: 3, mutantsDiscovered: 1, mutantsPerShard: [2, 1, 0]))
        )
        XCTAssertFalse(complete.stoppedOnAnError)
        XCTAssertEqual(complete.statusLines().last, "Shard 3 of 3 holds no mutant, so it has no results file.")

        let missing = try merge(
            file("/a/results.jsonl", header(1, count: 3, mutantsDiscovered: 1, mutantsPerShard: [1, 1, 1]), sum3),
            file("/c/results.jsonl", header(3, count: 3, mutantsDiscovered: 1, mutantsPerShard: [1, 1, 1]))
        )
        XCTAssertTrue(missing.stoppedOnAnError)
        XCTAssertEqual(missing.statusLines(), [
            "Report of 1 of 3 mutants, merged from the results files of 2 of 3 shards.",
            "Shard 1 of 3, 1 of its 1 mutants, from /a/results.jsonl: "
                + "the run has no end line, so it is still running, or it was killed or crashed.",
            "Shard 3 of 3, 0 of its 1 mutants, from /c/results.jsonl: "
                + "the run has no end line, so it is still running, or it was killed or crashed.",
            "No results file was given for shard 2 of 3, which holds 1 mutant.",
        ])
    }

    func test_aShardThatStoppedOnAnError_failsTheReport() throws {
        let merged = try merge(
            file("/a/results.jsonl", header(1), end(.aborted, detail: "tooManyBuildErrors")),
            file("/b/results.jsonl", header(2, mutantsDiscovered: 1), end())
        )

        XCTAssertTrue(merged.stoppedOnAnError)
        XCTAssertEqual(
            merged.statusLines()[1],
            "Shard 1 of 2, 0 of its 2 mutants, from /a/results.jsonl: the run stopped on an error (tooManyBuildErrors)."
        )
    }

    // Coverage that differed between the machines can leave out mutants that only some of them discovered.
    func test_discoveriesThatDiffer_areSaid() throws {
        let merged = try merge(
            file("/a/results.jsonl", header(1), sum3),
            file("/b/results.jsonl", header(2, mutantsInAllShards: 4, mutantsPerShard: [2, 2], allKeysSHA256: "b22"))
        )

        XCTAssertFalse(merged.discoveriesAgree)
        XCTAssertEqual(
            merged.statusLines().first,
            "Report of 1 mutants, merged from the results files of 2 of 2 shards."
        )
        XCTAssertEqual(
            merged.statusLines().last,
            "The shards discovered different mutants, 3 in shard 1 of 2 and 4 in shard 2 of 2, so a mutant that some "
                + "of them didn't discover may have no result."
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
}

private extension MergedShardsTests {
    typealias File = (path: String, records: [any Encodable])

    func file(_ path: String, _ records: any Encodable...) -> File {
        (path, records)
    }

    /// The header of shard `index` of `count`, which holds `mutantsDiscovered` of the 3 mutants by default.
    func header(
        _ index: Int,
        count: Int = 2,
        session: Int = 1,
        mutantsDiscovered: Int = 2,
        mutatedProjectPath: String = "/project_mutated",
        operators: [String] = ["RelationalOperatorReplacement"],
        provenance: Provenance = .fixture,
        project: ProjectTree = MergedShardsTests.tree,
        forced: [String]? = nil,
        mutantsInAllShards: Int = 3,
        mutantsPerShard: [Int]? = nil,
        allKeysSHA256: String = "a11"
    ) -> ResultsHeader {
        .make(
            formatVersion: session == 1 ? ResultsCoding.formatVersion : ResultsCoding.resumedFormatVersion,
            session: session,
            mutatedProjectPath: mutatedProjectPath,
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsDiscovered,
            project: project,
            provenance: provenance,
            operators: operators,
            forced: forced,
            shard: .make(
                index: index,
                count: count,
                mutantsInAllShards: mutantsInAllShards,
                mutantsPerShard: mutantsPerShard ?? (count == 2 ? [2, 1] : nil),
                allKeysSHA256: allKeysSHA256
            )
        )
    }

    func end(
        _ reason: ResultsEnd.Reason = .finished,
        detail: String? = nil,
        testDuration: Double = 100.5
    ) -> ResultsEnd {
        .make(reason: reason, detail: detail, testDurationSeconds: testDuration)
    }

    func encoded(_ records: any Encodable...) throws -> Data {
        try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
    }

    func read(_ file: File) throws -> (path: String, recorded: RecordedResults) {
        let data = try file.records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        return (file.path, try RecordedResults.read(data, path: file.path))
    }

    func merge(_ files: File...) throws -> MergedShards {
        try MergedShards.merge(files.map(read), forcing: false, ignoring: [])
    }

    func assertRefused(
        _ files: [File],
        _ reasons: [MergeRefusal],
        saying message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try MergedShards.merge(files.map(read), forcing: false, ignoring: []),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual((error as? MergeRefused)?.reasons, reasons, file: file, line: line)
            if let message {
                XCTAssertEqual(reasons.first?.description, message, file: file, line: line)
            }
        }
    }
}
