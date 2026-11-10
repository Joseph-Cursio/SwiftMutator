@testable import muterCore
import XCTest

extension RecordedResultsStatusTests {
    var path: String { "/logs/results.jsonl" }

    var header: ResultsHeader { ResultsHeader.make(mutantsDiscovered: 3) }

    var sum: MutantResult { MutantResult.make(path: "Sources/Sum.swift") }

    var product: MutantResult { MutantResult.make(path: "Sources/Product.swift") }

    var older: String {
        "/logs/Oct 31, 2026 at 7:08 PM/results.jsonl"
    }

    var oldest: String {
        "/logs/Oct 30, 2026 at 9:15 AM/results.jsonl"
    }

    /// `result`, as a session that reused it from the results file at `resultsFile` writes it.
    func kept(_ result: MutantResult, from resultsFile: String) -> MutantResult {
        var copy = result
        copy.reusedFrom = ReusedFrom(resultsFile: resultsFile, session: 1, despiteChanges: false)
        return copy
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
}
