import ArgumentParser
@testable import muterCore
import XCTest

extension ReportBaselineTests {
    /// A mutant of code no test ran, at column 9 of `line` of `path`, which would replace `*` with `/`.
    func uncovered(_ path: String, line: Int) -> UncoveredMutant {
        UncoveredMutant(
            key: MutantKey(path: path, mutationOperatorId: .ror, line: line, column: 9, occurrence: 0),
            snapshot: .make(before: "*", after: "/")
        )
    }

    /// A baseline file at `baselinePath` of `ResultsHeader.make()`'s scope, recording `survivors`, and `score`.
    func writeBaseline(survivors: [MutantResult], score: BaselineFile.Score = .init(killed: 0, scored: 0)) throws {
        let file = BaselineFile(
            path: baselinePath,
            swiftMutator: "1.0.0",
            score: score,
            scope: scope,
            survivors: survivors.map {
                BaselineSurvivor(
                    mutant: $0.key,
                    outcome: .survived,
                    before: $0.snapshot.before,
                    after: $0.snapshot.after
                )
            }
        )
        XCTAssertTrue(file.save(using: FileManager.default))
    }

    /// The header of shard `index` of 2 of the 3 mutants: Alpha.swift:3 and Zeta.swift:9 in shard 1, Zeta.swift:10 in
    /// shard 2.
    func shardHeader(
        _ index: Int,
        mutantsDiscovered: Int,
        allKeysSHA256: String = "a11",
        skipCoverage: Bool = true
    ) -> ResultsHeader {
        ResultsHeader.make(
            mutantsDiscovered: mutantsDiscovered,
            mutantsToTest: mutantsDiscovered,
            project: ProjectTree(
                listedBy: .git,
                files: ["Sources/Zeta.swift": "ab12"],
                excluded: [],
                treeSHA256: "cd34"
            ),
            skipCoverage: skipCoverage,
            shard: .make(
                index: index,
                count: 2,
                mutantsInAllShards: 3,
                mutantsPerShard: [2, 1],
                allKeysSHA256: allKeysSHA256
            )
        )
    }

    func report(_ arguments: String...) throws {
        try report(arguments: arguments)
    }

    func report(arguments: [String]) throws {
        let command = try MuterCommand.parseAsRoot(["report"] + arguments)
        guard let report = command as? Report else {
            XCTFail("Expected the report command, got \(command)")
            return
        }
        try report.run()
    }

    func write(_ records: any Encodable..., to path: String) throws {
        try write(records: records, to: path)
    }

    func write(records: [any Encodable], to path: String) throws {
        let data = try records.reduce(into: Data()) { data, record in
            data += try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
