@testable import muterCore
import XCTest

final class RecordedResultsStatusTests: XCTestCase {
    private let path = "/logs/results.jsonl"
    private let header = ResultsHeader.make(mutantsDiscovered: 3)
    private let sum = MutantResult.make(path: "Sources/Sum.swift")
    private let product = MutantResult.make(path: "Sources/Product.swift")

    func test_aFinishedRun() throws {
        let recorded = try read(file(header, sum, product, ResultsEnd.make(reason: .finished)))

        XCTAssertEqual(
            recorded.statusLines(path: path),
            ["Report of 2 of 3 mutants, from /logs/results.jsonl: the run finished."]
        )
    }

    func test_anInterruptedRun_namesTheSignal() throws {
        let recorded = try read(file(header, sum, ResultsEnd.make(reason: .interrupted, detail: "SIGINT")))

        XCTAssertEqual(
            recorded.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run was interrupted by SIGINT."]
        )
    }

    func test_anInterruptionWithoutASignal() throws {
        let recorded = try read(file(header, sum, ResultsEnd.make(reason: .interrupted, detail: nil)))

        XCTAssertEqual(
            recorded.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run was interrupted."]
        )
    }

    func test_anAbortedRun_namesTheError() throws {
        let named = try read(file(header, sum, ResultsEnd.make(reason: .aborted, detail: "tooManyBuildErrors")))
        let unnamed = try read(file(header, sum, ResultsEnd.make(reason: .aborted, detail: nil)))

        XCTAssertEqual(
            named.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run stopped on an error (tooManyBuildErrors)."]
        )
        XCTAssertEqual(
            unnamed.statusLines(path: path),
            ["Report of 1 of 3 mutants, from /logs/results.jsonl: the run stopped on an error."]
        )
    }

    func test_aFileWithoutAnEndLine_mayStillBeRunning() throws {
        let someTested = try read(file(header, sum))
        let noneTested = try read(file(header))

        XCTAssertEqual(
            someTested.statusLines(path: path),
            [
                "Report of 1 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
        XCTAssertEqual(
            noneTested.statusLines(path: path),
            [
                "Report of 0 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }

    func test_skippedLines_areNumbered_andACutOffLastLineIsSaid() throws {
        let garbled = Data("{\"kind\":\"mutant\",\"pa\n".utf8)
        let oneSkipped = try read(file(header, sum) + garbled + file(ResultsEnd.make()))
        let cutOff = try read(file(header, sum) + garbled + garbled + file(product) + line(product).prefix(40))

        XCTAssertEqual(
            oneSkipped.statusLines(path: path),
            [
                "Report of 1 of 3 mutants, from /logs/results.jsonl: the run finished.",
                "Skipped 1 line that didn't read: 3.",
            ]
        )
        XCTAssertEqual(
            cutOff.statusLines(path: path),
            [
                "Report of 2 of 3 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
                "Skipped 3 lines that didn't read: 3, 4, 6; the last was cut off as it was written.",
            ]
        )
    }

    func test_theLastSessionSaysHowTheRunEnded() throws {
        let interrupted = ResultsEnd.make(reason: .interrupted, detail: "SIGINT")
        let resumed = ResultsHeader.make(session: 2, mutantsDiscovered: 4)
        let retested = MutantResult.make(session: 2, path: sum.path, outcome: .passed)
        let quotient = MutantResult.make(session: 2, path: "Sources/Quotient.swift")

        let finished = try read(
            file(header, sum, interrupted, resumed, retested, quotient, ResultsEnd.make(session: 2, reason: .finished))
        )
        let stillRunning = try read(file(header, sum, ResultsEnd.make(reason: .finished), resumed, quotient))

        XCTAssertEqual(
            finished.statusLines(path: path),
            ["Report of 2 of 4 mutants, from /logs/results.jsonl: the run finished."]
        )
        XCTAssertEqual(
            stillRunning.statusLines(path: path),
            [
                "Report of 2 of 4 mutants, from /logs/results.jsonl: "
                    + "the run has no end line, so it is still running, or it was killed or crashed.",
            ]
        )
    }
}

private extension RecordedResultsStatusTests {
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
