import Foundation
@testable import muterCore

extension RecordedResultsTests {
    var path: String { "/logs/results.jsonl" }

    var header: ResultsHeader { ResultsHeader.make() }

    var sum: MutantResult { MutantResult.make(path: "Sources/Sum.swift", finishedAt: ResultsHeader.fixedStart + 31.25) }

    var product: MutantResult {
        MutantResult.make(path: "Sources/Product.swift", finishedAt: ResultsHeader.fixedStart + 62.5)
    }

    var end: ResultsEnd { ResultsEnd.make(testDurationSeconds: 100.5, recorded: 2) }

    var resumed: ResultsHeader {
        ResultsHeader.make(
            formatVersion: ResultsCoding.resumedFormatVersion,
            session: 2,
            startedAt: ResultsHeader.fixedStart + 3_600
        )
    }

    func projectTree(_ files: [String: String]) -> ProjectTree {
        ProjectTree(listedBy: .git, files: files, excluded: [], treeSHA256: ProjectTree.treeHash(of: files))
    }

    func resumed(session: Int, _ delta: ProjectTreeDelta) -> ResultsHeader {
        ResultsHeader.make(
            formatVersion: ResultsCoding.projectDeltaFormatVersion,
            session: session,
            projectDelta: delta,
            mutantsReused: 0
        )
    }

    func read(_ data: Data) throws -> RecordedResults {
        try RecordedResults.read(data, path: path)
    }

    func line(_ record: some Encodable) throws -> Data {
        try ResultsCoding.encoder.encode(record) + Data("\n".utf8)
    }

    func file(_ records: any Encodable...) throws -> Data {
        try records.reduce(into: Data()) { data, record in data += try line(record) }
    }

    func propertyRerun(of result: MutantResult, outcome: TestSuiteOutcome) -> PropertyRerunResult {
        PropertyRerunResult(
            session: result.session,
            path: result.path,
            line: result.line,
            column: result.column,
            occurrence: result.occurrence,
            mutationOperatorId: result.mutationOperatorId,
            outcome: outcome,
            endedBy: .exited,
            exitStatus: outcome == .passed ? 0 : 1,
            durationSeconds: 1.5,
            worker: 0,
            finishedAt: result.finishedAt + 1,
            killedBy: outcome == .passed ? nil : [.init(name: "ordered()", location: "SortProperties.swift:8:5")],
            failedTestCount: outcome == .passed ? nil : 1,
            firstFailedTestLine: nil,
            log: nil
        )
    }
}
