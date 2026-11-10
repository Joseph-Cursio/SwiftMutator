@testable import muterCore
import XCTest

extension MergedShardsTests {
    /// The project tree every shard's header holds unless a test gives its own.
    static let tree = ProjectTree(
        listedBy: .git,
        files: ["Sources/Sum.swift": "ab12", "README.md": "ef56"],
        excluded: [],
        treeSHA256: "cd34"
    )

    // Shard 1 of 2 holds Sum.swift:3 and :9, shard 2 Alpha.swift:5.
    var sum3: MutantResult { MutantResult.make(path: "Sources/Sum.swift", line: 3, outcome: .failed) }
    var sum9: MutantResult { MutantResult.make(path: "Sources/Sum.swift", line: 9, outcome: .passed) }
    var alpha5: MutantResult { MutantResult.make(path: "Sources/Alpha.swift", line: 5, outcome: .failed) }

    /// The fixture's provenance, but for another SwiftMutator build.
    var otherBuild: Provenance {
        Provenance(
            swiftMutator: .init(version: "0.2.0", executablePath: nil, executableSHA256: "ffff"),
            toolchain: Provenance.fixture.toolchain,
            processIdentifier: 1,
            host: "ci.local",
            arguments: []
        )
    }

    typealias File = (path: String, records: [any Encodable])

    func file(_ path: String, _ records: any Encodable...) -> File {
        (path, records)
    }

    /// The header of shard `index` of `count`, which holds `mutantsDiscovered` of the 3 mutants: by default its share
    /// of `mutantsPerShard`, which by default is 2 and 1 of 2 shards, and as even as can be of more.
    func header(
        _ index: Int,
        count: Int = 2,
        session: Int = 1,
        mutantsDiscovered: Int? = nil,
        mutatedProjectPath: String = "/project_mutated",
        operators: [String] = ["RelationalOperatorReplacement"],
        provenance: Provenance = .fixture,
        project: ProjectTree = MergedShardsTests.tree,
        forced: [String]? = nil,
        mutantsInAllShards: Int = 3,
        mutantsPerShard: [Int]? = nil,
        allKeysSHA256: String = "a11",
        sample: SampleSelection? = nil
    ) -> ResultsHeader {
        let shard = ShardSelection.make(
            index: index,
            count: count,
            mutantsInAllShards: mutantsInAllShards,
            mutantsPerShard: mutantsPerShard ?? (count == 2 ? [2, 1] : nil),
            allKeysSHA256: allKeysSHA256
        )
        let own = mutantsDiscovered
            ?? (shard.mutantsPerShard.indices.contains(index - 1) ? shard.mutantsPerShard[index - 1] : 0)
        return .make(
            formatVersion: session == 1 ? ResultsCoding.formatVersion : ResultsCoding.resumedFormatVersion,
            session: session,
            mutatedProjectPath: mutatedProjectPath,
            mutantsDiscovered: own,
            mutantsToTest: own,
            project: project,
            provenance: provenance,
            operators: operators,
            forced: forced,
            shard: shard,
            sample: sample
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
