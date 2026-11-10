import ArgumentParser
@testable import muterCore
import TestingExtensions
import XCTest

extension ReportBaselineTests {
    // The results header records the mutants of code no test ran, so `report` sees what the run saw: a baseline file
    // records them as survivors not covered, and a new one is a new survivor.
    func test_theMutantsOfCodeNoTestRan_areRecorded_andCompared_fromTheResultsHeader() async throws {
        var header = ResultsHeader.make()
        header.mutantsNotCovered = [uncovered("Sources/Zeta.swift", line: 20)]
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath, "--write-baseline", baselinePath)

        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10, 20])
        XCTAssertEqual(written.survivors.map(\.outcome), [.survived, .survived, .notCovered])
        XCTAssertEqual(written.score, .init(killed: 1, scored: 3), "no score counts them")

        header.mutantsNotCovered?.append(uncovered("Sources/New.swift", line: 4))
        try write(header, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        await AssertThrowsError(try await report(resultsPath, "--baseline", baselinePath)) { error in
            XCTAssertEqual(error as? ExitCode, .scoreBelowThreshold)
        }
        XCTAssertEqual(
            standardError.linesPassed.last,
            "  Sources/New.swift:4:9 RelationalOperatorReplacement: * → / (coverage left it out)"
        )
    }

    // Results whose header doesn't record the mutants of code no test ran, with coverage on, as an older SwiftMutator's
    // or a run of a test plan it made, would make a baseline file without them, against which each would be new: none
    // is written, and a comparison says new code no test ran isn't seen. With `skipCoverage` there are none to record.
    func test_resultsThatDontRecordTheMutantsOfCodeNoTestRan_writeNone_andSaySo() async throws {
        try write(ResultsHeader.make(skipCoverage: false), zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)

        try await report(resultsPath, "--write-baseline", baselinePath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
        XCTAssertTrue(
            standardError.linesPassed.contains(
                "No baseline file was saved to \(baselinePath): the results, of an older SwiftMutator or of a test "
                    + "plan it made, don't record the mutants of code no test ran, and a baseline file holds a whole "
                    + "run's survivors."
            ),
            "\(standardError.linesPassed)"
        )

        XCTAssertTrue(BaselineFile(
            path: baselinePath,
            swiftMutator: "1.0.0",
            score: .init(killed: 1, scored: 3),
            scope: BaselineScope(header: ResultsHeader.make(skipCoverage: false)),
            survivors: []
        ).save(using: FileManager.default))
        try await report(resultsPath, "--baseline", baselinePath, "--max-new-survivors", "2")
        let unseen = "The results don't record the mutants of code no test ran, so new code no test ran isn't seen."
        XCTAssertTrue(
            standardError.linesPassed.contains { $0.hasSuffix(unseen) },
            "\(standardError.linesPassed)"
        )

        var recorded = ResultsHeader.make(skipCoverage: false)
        recorded.mutantsNotCovered = []
        try write(recorded, zeta9, alpha3, zeta10, ResultsEnd.make(), to: resultsPath)
        try await report(resultsPath, "--write-baseline", baselinePath)
        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(written.survivors.map(\.mutant.line), [9, 10])
    }

    // Each shard records those it holds, and the merge takes them all, each once by its key.
    func test_mergedShards_takeEveryShardsMutantsOfCodeNoTestRan() async throws {
        let first = "\(directory)/1.jsonl"
        let second = "\(directory)/2.jsonl"
        var one = shardHeader(1, mutantsDiscovered: 2)
        one.mutantsNotCovered = [uncovered("Sources/Zeta.swift", line: 30), uncovered("Sources/Alpha.swift", line: 8)]
        var two = shardHeader(2, mutantsDiscovered: 1)
        two.mutantsNotCovered = [uncovered("Sources/Zeta.swift", line: 30), uncovered("Sources/Zeta.swift", line: 40)]
        try write(one, zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(two, zeta10, ResultsEnd.make(), to: second)

        try await report(first, second, "--write-baseline", baselinePath)

        let written = try BaselineFile.load(at: baselinePath, using: FileManager.default)
        XCTAssertEqual(
            written.survivors.map { "\($0.mutant.path):\($0.mutant.line)" },
            [
                "Sources/Alpha.swift:8",
                "Sources/Zeta.swift:9",
                "Sources/Zeta.swift:10",
                "Sources/Zeta.swift:30",
                "Sources/Zeta.swift:40",
            ]
        )

        // A shard whose header doesn't record them, with coverage on, leaves them unknown for the merge.
        try FileManager.default.removeItem(atPath: baselinePath)
        var recorded = shardHeader(1, mutantsDiscovered: 2, skipCoverage: false)
        recorded.mutantsNotCovered = one.mutantsNotCovered
        try write(recorded, zeta9, alpha3, ResultsEnd.make(), to: first)
        try write(shardHeader(2, mutantsDiscovered: 1, skipCoverage: false), zeta10, ResultsEnd.make(), to: second)
        try await report(first, second, "--write-baseline", baselinePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: baselinePath))
    }
}
