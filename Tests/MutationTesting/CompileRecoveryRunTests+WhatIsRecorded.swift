@testable import muterCore
import SwiftParser
import TestingExtensions
import XCTest

extension CompileRecoveryRunTests {
    // The gate of `report` reads only the results file, so its line has to say so.
    func test_aMutantTakenOutWithOthers_isSaidToBe_inItsLine_andTheOutcome() async throws {
        let bad = try XCTUnwrap(ids.first)
        let keyword = try XCTUnwrap(rewritten.range(of: "if __SwiftMutator"))
        let before = rewritten[..<keyword.lowerBound].utf8
        let line = before.count { $0 == UInt8(ascii: "\n") } + 1
        let lineStart = before.lastIndex(of: UInt8(ascii: "\n")).map { before.index(after: $0) } ?? before.startIndex
        let column = before.distance(from: lineStart, to: before.endIndex) + 1
        ioDelegate.baselineTestLogs = ["\(path):\(line):\(column): error: type mismatch", "Build complete!"]
        let chain = mapping.mutationSchemata.filter { $0.position.line == mapping.mutationSchemata[0].position.line }
        ioDelegate.testSuiteOutcomes = [.buildError, .passed]
            + Array(repeating: .failed, count: ids.count - chain.count)
        XCTAssertTrue(chain.map(\.id).contains(bad))

        let result = try await sut.run(with: state)

        let records = try resultsFiles.records(MutantResult.self)
        XCTAssertEqual(
            Set(records.filter { $0.leftOutWithOthers == true }.map(\.switchID)),
            Set(chain.map(\.id))
        )
        guard case let .mutationTestOutcomeGenerated(outcome)? = result.first else {
            XCTFail("\(result)")
            return
        }
        XCTAssertEqual(outcome.mutations.count(where: \.leftOutWithOthers), chain.count)
    }

    func test_aMutantThatItselfDoesntCompile_isntSaidToGoWithOthers() async throws {
        ioDelegate.baselineTestLogs = [try errorLog(for: try XCTUnwrap(ids.first)), "Build complete!"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed] + Array(repeating: .failed, count: ids.count - 1)

        _ = try await sut.run(with: state)

        XCTAssertTrue(try resultsFiles.records(MutantResult.self).allSatisfy { $0.leftOutWithOthers == nil })
        XCTAssertFalse(resultsFiles.lines.contains { $0.contains("leftOutWithOthers") })
    }

    /// Records a real results file, as `report` will read it, and reads it back: `report` must reach the outcome the
    /// run did.
    func test_reportOfTheResultsFile_isTheRunsOutcome() async throws {
        let directory = try makeTemporaryDirectory()
        current.resultsFiles = ResultsFile.Opener()
        current.fileManager = fileManager
        state.loggingDirectory = directory
        let bad = try XCTUnwrap(ids.first)
        ioDelegate.baselineTestLogs = [try errorLog(for: bad), "Build complete!"]
        ioDelegate.testSuiteOutcomes = [.buildError, .passed] + Array(repeating: .failed, count: ids.count - 1)

        let result = try await sut.run(with: state)

        guard case let .mutationTestOutcomeGenerated(outcome)? = result.first else {
            XCTFail("\(result)")
            return
        }
        let resultsPath = "\(directory)/results.jsonl"
        let recorded = try RecordedResults.read(Data(contentsOf: URL(fileURLWithPath: resultsPath)), path: resultsPath)
        let reported = recorded.mutationTestOutcome()
        XCTAssertEqual(reported.mutations.map(\.testSuiteOutcome), outcome.mutations.map(\.testSuiteOutcome))
        XCTAssertEqual(reported.mutations.map(\.key), outcome.mutations.map(\.key))
        XCTAssertEqual(reported.mutations.map(\.durationSeconds), outcome.mutations.map(\.durationSeconds))
        XCTAssertEqual(reported.mutations.map(\.killingTests), outcome.mutations.map(\.killingTests))
        XCTAssertEqual(reported.mutations.map(\.leftOutWithOthers), outcome.mutations.map(\.leftOutWithOthers))
        XCTAssertFalse(reported.sampleIsCutShort)
    }
}
